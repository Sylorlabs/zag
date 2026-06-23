"""
gpu/mlir_emitter.py — Zag → MLIR textual IR emitter.

Walks a type-annotated Zag AST (output of zagc's Sema pass) and emits MLIR
in textual form (.mlir). The output is a complete, self-contained MLIR module
that mlir-opt can then lower to a target-specific representation via the
pipeline in gpu/lowering.py.

Dialect strategy
────────────────
  func    — host functions, gpu device helper functions
  gpu     — gpu.func (kernels), gpu.thread_id, gpu.block_id, gpu.return,
             gpu.launch_func (for host-side dispatch stubs)
  arith   — integer/float arithmetic on standard types
  memref  — slices ([]T) and GPU buffers (gpu_buf<T>)
  vector  — VSA hypervectors (vector<Nxi1>)
  scf     — structured control flow: scf.if, scf.while
  cf      — unstructured jumps (used only for switch lowering)
  index   — index arithmetic
  llvm    — struct passthrough (for Zag structs)

Custom type encoding
────────────────────
  p32     — carried as i32; arithmetic routed to @zag_p32_{add,sub,mul,div}
  l32     — carried as i32; arithmetic routed to @zag_l32_{add,sub,mul,div}
  mx_fp8  — carried as f8E4M3FN (native MLIR type); block scale in separate memref
  vsa_b<N>— carried as vector<Nxi1>; bind = XOR, bundle via vector.reduce, etc.
  bf16    — native bf16
  quire   — memref<8xi64> (the 512-bit accumulator on the stack)

SSA strategy
────────────
All Zag `let` bindings that are subsequently *reassigned* are lowered as
memref.alloca + load/store (the standard imperative-to-SSA bridge).  Pure
single-assignment lets become direct SSA values.  This is correct code that
mlir-opt --mem2reg will clean up into pure SSA automatically.
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from gpu.types import (
    zag_to_mlir, is_vsa_type, is_gpu_buf, vsa_dim, gpu_buf_elem,
    POSIT_MLIR_OPS, LNS_MLIR_OPS, runtime_decls, GPU_DIM_NAMES,
    GPU_SCALAR_TYPES,
)


# ── helpers from zagc (duplicated here to keep this file importable standalone)

def _is_posit(ty):  return ty in ("p8", "p16", "p32", "p64")
def _is_lns(ty):    return ty in ("l16", "l32")
def _is_int(ty):    return ty in {"i8","i16","i32","i64","u8","u16","u32","u64","usize","bool"}
def _is_float(ty):  return ty in {"f32","f64","bf16","mx_fp8","mx_fp4","float_lit"}
def _is_fn_type(ty):return isinstance(ty, str) and ty.startswith("fn(")


class MLIREmitter:
    """Emit MLIR textual IR from a type-annotated Zag AST."""

    def __init__(self, sema, target: str = "nvidia"):
        self.sema = sema
        self.target = target          # 'nvidia' | 'amd' | 'vulkan'
        self._ctr = 0
        self._lines: list[str] = []
        self._indent = 0
        self._scope: dict[str, tuple] = {}   # name → (mlir_val, is_alloca, zag_ty)
        self._mutated: set[str] = set()      # names that are reassigned (need alloca)
        self._block_ctr = 0
        self._types_used: set[str] = set()
        self._gpu_module_lines: list[str] = []   # buffered kernel definitions

    # ── public entry point ────────────────────────────────────────────────────

    def emit_module(self) -> str:
        self._collect_types()

        self._emit_header()
        self._out("module attributes {gpu.container_module} {")
        self._indent += 1

        # Runtime helper declarations (posit, lns, etc.)
        for d in runtime_decls(self._types_used):
            self._out(d)

        # Separate kernels (gpu.func) from host functions (func.func)
        host_fns = []
        kernels = []
        for f in self.sema.fns.values():
            if f.extern:
                continue
            if "@kernel" in f.annots or "@device" in f.annots:
                kernels.append(f)
            else:
                host_fns.append(f)

        # Emit the gpu.module containing all kernels
        if kernels:
            self._out("gpu.module @zag_kernels {")
            self._indent += 1
            for f in kernels:
                self._emit_kernel_fn(f)
            self._indent -= 1
            self._out("} // gpu.module @zag_kernels")
            self._out("")

        # Emit host functions
        for f in host_fns:
            self._emit_host_fn(f)

        self._indent -= 1
        self._out("} // module")

        return "\n".join(self._lines) + "\n"

    # ── type collection ───────────────────────────────────────────────────────

    def _collect_types(self):
        for f in self.sema.fns.values():
            for p in f.params:
                self._types_used.add(p.pty)
            self._types_used.add(f.ret)

    # ── output helpers ────────────────────────────────────────────────────────

    def _out(self, line: str = ""):
        self._lines.append("  " * self._indent + line)

    def _fresh(self, prefix="v") -> str:
        self._ctr += 1
        return f"%{prefix}{self._ctr}"

    def _fresh_block(self) -> str:
        self._block_ctr += 1
        return f"^bb{self._block_ctr}"

    def _mtype(self, zag_ty: str) -> str:
        return zag_to_mlir(zag_ty)

    # ── function emission ─────────────────────────────────────────────────────

    def _emit_host_fn(self, f):
        """Emit a func.func for host-side Zag functions."""
        ret_ty = self._mtype(f.ret)
        ret_part = f" -> {ret_ty}" if ret_ty else ""
        params = ", ".join(f"%{p.name}: {self._mtype(p.pty)}" for p in f.params)
        # Attributes: carry capability annotations for documentation
        attrs = ""
        if f.annots:
            ann_str = ", ".join(f'"{a}"' for a in f.annots)
            attrs = f' attributes {{zag.caps = [{ann_str}]}}'

        self._out(f"func.func @{self._mangle(f.name)}({params}){ret_part}{attrs} {{")
        self._indent += 1

        scope = {p.name: (f"%{p.name}", False, p.pty) for p in f.params}
        self._mutated = self._collect_mutated(f.body)

        # Alloca mutable variables up front
        for vname in self._mutated:
            ty = self._find_let_type(f.body, vname)
            if ty:
                slot = self._fresh("slot")
                self._out(f"{slot} = memref.alloca() : memref<{self._mtype(ty)}>")
                scope[vname] = (slot, True, ty)

        self._emit_block(f.body, scope, f.ret)
        if f.ret == "void":
            self._out("return")

        self._indent -= 1
        self._out("} // func.func @" + self._mangle(f.name))
        self._out("")

    def _emit_kernel_fn(self, f):
        """Emit a gpu.func ... kernel { ... gpu.return } inside gpu.module."""
        params = ", ".join(f"%{p.name}: {self._mtype(p.pty)}" for p in f.params)
        self._out(f"gpu.func @{self._mangle(f.name)}({params}) kernel {{")
        self._indent += 1

        scope = {p.name: (f"%{p.name}", False, p.pty) for p in f.params}
        self._mutated = self._collect_mutated(f.body)

        for vname in self._mutated:
            ty = self._find_let_type(f.body, vname)
            if ty:
                slot = self._fresh("slot")
                self._out(f"{slot} = memref.alloca() : memref<{self._mtype(ty)}>")
                scope[vname] = (slot, True, ty)

        self._emit_block(f.body, scope, "void")
        self._out("gpu.return")

        self._indent -= 1
        self._out("} // gpu.func @" + self._mangle(f.name))
        self._out("")

    # ── statement emission ────────────────────────────────────────────────────

    def _emit_block(self, stmts, scope: dict, ret_ty: str):
        for s in stmts:
            self._emit_stmt(s, scope, ret_ty)

    def _emit_stmt(self, s, scope, ret_ty):
        kind = type(s).__name__
        if kind == "Let":
            val, zty = self._emit_expr(s.expr, scope)
            declared_ty = s.dty or zty
            if s.name in scope and scope[s.name][1]:  # alloca slot exists
                slot, _, _ = scope[s.name]
                self._out(f"memref.store {val}, {slot}[] : memref<{self._mtype(declared_ty)}>")
            else:
                scope[s.name] = (val, False, declared_ty)

        elif kind == "Assign":
            val, _ = self._emit_expr(s.expr, scope)
            if type(s.target).__name__ == "Index":
                # Array/slice element assignment: memref.store val, base[idx]
                base_node = s.target.base
                idx_node  = s.target.idx
                base_val, base_ty = self._emit_expr(base_node, scope)
                idx_val,  _       = self._emit_expr(idx_node,  scope)
                elem_ty = base_ty[2:] if base_ty.startswith("[]") else "i32"
                self._out(f"memref.store {val}, {base_val}[{idx_val}] : memref<?x{self._mtype(elem_ty)}>")
            else:
                target_name = _varname(s.target)
                if target_name and target_name in scope:
                    slot, is_alloca, zty = scope[target_name]
                    if is_alloca:
                        self._out(f"memref.store {val}, {slot}[] : memref<{self._mtype(zty)}>")
                    else:
                        scope[target_name] = (val, False, zty)
                else:
                    self._out(f"// unhandled assign target: {type(s.target).__name__}")

        elif kind == "Return":
            if s.expr:
                val, zty = self._emit_expr(s.expr, scope)
                self._out(f"return {val} : {self._mtype(zty or ret_ty)}")
            else:
                self._out("return")

        elif kind == "If":
            cond, _ = self._emit_expr(s.cond, scope)
            then_res = self._fresh("if")
            # Use scf.if for structured control flow
            if ret_ty == "void":
                self._out(f"scf.if {cond} {{")
                self._indent += 1
                self._emit_block(s.then, dict(scope), ret_ty)
                self._indent -= 1
                if s.els:
                    self._out("} else {")
                    self._indent += 1
                    self._emit_block(s.els, dict(scope), ret_ty)
                    self._indent -= 1
                self._out("}")
            else:
                mty = self._mtype(ret_ty)
                self._out(f"{then_res} = scf.if {cond} -> {mty} {{")
                self._indent += 1
                self._emit_block(s.then, dict(scope), ret_ty)
                self._indent -= 1
                if s.els:
                    self._out("} else {")
                    self._indent += 1
                    self._emit_block(s.els, dict(scope), ret_ty)
                    self._indent -= 1
                self._out("}")

        elif kind == "While":
            # scf.while: before-region tests cond, after-region is the loop body
            cond_val, _ = self._emit_expr(s.cond, scope)
            self._out(f"scf.while : () -> () {{")
            self._indent += 1
            # before block: re-evaluate condition
            cond2, _ = self._emit_expr(s.cond, scope)
            self._out(f"scf.condition({cond2})")
            self._indent -= 1
            self._out("} do {")
            self._indent += 1
            self._emit_block(s.body, dict(scope), "void")
            self._out("scf.yield")
            self._indent -= 1
            self._out("}")

        elif kind == "Switch":
            subj_val, subj_ty = self._emit_expr(s.subject, scope)
            # Lower to cf dialect: compute block addresses manually
            # For simplicity in bootstrap, emit as a chain of scf.if equality checks
            if subj_ty in self.sema.enums:
                members = self.sema.enums[subj_ty].members
                for tag, cap, body in s.arms:
                    tag_idx = members.index(tag)
                    tag_const = self._fresh("tag")
                    self._out(f"{tag_const} = arith.constant {tag_idx} : i32")
                    eq = self._fresh("eq")
                    self._out(f"{eq} = arith.cmpi eq, {subj_val}, {tag_const} : i32")
                    self._out(f"scf.if {eq} {{")
                    self._indent += 1
                    self._emit_block(body, dict(scope), "void")
                    self._indent -= 1
                    self._out("}")
            elif subj_ty in self.sema.unions:
                tag_field = self._fresh("tag")
                self._out(f"{tag_field} = llvm.extractvalue {subj_val}[0] : !llvm.struct<...>")
                for i, (tag, cap, body) in enumerate(s.arms):
                    tag_const = self._fresh("tc")
                    self._out(f"{tag_const} = arith.constant {i} : i32")
                    eq = self._fresh("eq")
                    self._out(f"{eq} = arith.cmpi eq, {tag_field}, {tag_const} : i32")
                    self._out(f"scf.if {eq} {{")
                    self._indent += 1
                    arm_scope = dict(scope)
                    if cap:
                        payload = self._fresh("payload")
                        self._out(f"{payload} = llvm.extractvalue {subj_val}[1, {i}] : !llvm.struct<...>")
                        arm_scope[cap] = (payload, False, self.sema.unions[subj_ty].fields[i].pty)
                    self._emit_block(body, arm_scope, "void")
                    self._indent -= 1
                    self._out("}")
            else:
                self._out(f"// switch on non-enum/union type {subj_ty} (unimplemented)")

        elif kind == "ExprStmt":
            self._emit_expr(s.expr, scope)

    # ── expression emission ───────────────────────────────────────────────────

    def _emit_expr(self, e, scope) -> tuple:
        """Emit ops for expression e; return (mlir_value_name, zag_type)."""
        kind = type(e).__name__

        if kind == "Lit":
            return self._emit_lit(e)

        if kind == "Var":
            if e.name in scope:
                val, is_alloca, zty = scope[e.name]
                if is_alloca:
                    loaded = self._fresh("ld")
                    self._out(f"{loaded} = memref.load {val}[] : memref<{self._mtype(zty)}>")
                    return loaded, zty
                return val, zty
            # Named function used as value — emit a func.constant
            if e.name in self.sema.fns:
                f = self.sema.fns[e.name]
                ty = f"fn({',' .join(p.pty for p in f.params)}){f.ret}"
                v = self._fresh("fn")
                ps = ", ".join(self._mtype(p.pty) for p in f.params)
                rt = self._mtype(f.ret)
                self._out(f"{v} = func.constant @{self._mangle(e.name)} : ({ps}) -> {rt}")
                return v, ty
            return f"%{e.name}", e.ty or "i32"

        if kind == "Bin":
            return self._emit_bin(e, scope)

        if kind == "Un":
            v, ty = self._emit_expr(e.e, scope)
            res = self._fresh("u")
            if e.op == "!":
                t = self._fresh("t")
                self._out(f"{t} = arith.constant true : i1")
                self._out(f"{res} = arith.xori {v}, {t} : i1")
                return res, "bool"
            if e.op == "-":
                if _is_float(ty):
                    self._out(f"{res} = arith.negf {v} : {self._mtype(ty)}")
                else:
                    self._out(f"{res} = arith.negsi {v} : {self._mtype(ty)}")
                return res, ty
            return v, ty

        if kind == "Index":
            base, bty = self._emit_expr(e.base, scope)
            idx, _ = self._emit_expr(e.idx, scope)
            res = self._fresh("el")
            if bty.startswith("[]"):
                elem_ty = bty[2:]
                self._out(f"{res} = memref.load {base}[{idx}] : memref<?x{self._mtype(elem_ty)}>")
                return res, elem_ty
            self._out(f"// index into unsupported base type {bty}")
            return res, "i32"

        if kind == "Field":
            if type(e.base).__name__ == "Var" and hasattr(e.base, 'name') and e.base.name in self.sema.enums:
                ed = self.sema.enums[e.base.name]
                idx = ed.members.index(e.fname)
                v = self._fresh("enum")
                self._out(f"{v} = arith.constant {idx} : i32")
                return v, e.base.name
            base, bty = self._emit_expr(e.base, scope)
            if bty and bty.startswith("[]") and e.fname == "len":
                res = self._fresh("len")
                self._out(f"{res} = memref.dim {base}, %c0 : memref<?x{self._mtype(bty[2:])}>")
                return res, "i32"
            res = self._fresh("field")
            # Struct field access via llvm.extractvalue
            if bty in self.sema.structs:
                fields = [p.name for p in self.sema.structs[bty].fields]
                fidx = fields.index(e.fname) if e.fname in fields else 0
                fty = self.sema.field_type(bty, e.fname) or "i32"
                self._out(f"{res} = llvm.extractvalue {base}[{fidx}] : {self._mtype(bty)}")
                return res, fty
            return res, "i32"

        if kind == "StructLit":
            nm = e.inst_sname or e.sname
            vals = []
            for fn_, val in e.fields:
                v, _ = self._emit_expr(val, scope)
                vals.append(v)
            res = self._fresh("st")
            if nm in self.sema.structs:
                sty = self.sema.structs[nm]
                mlir_ty = self._mtype(nm)
                inner = ", ".join(f"{v} : {self._mtype(p.pty)}" for v, p in zip(vals, sty.fields))
                self._out(f"{res} = llvm.mlir.undef : {mlir_ty}")
                for i, (v, p) in enumerate(zip(vals, sty.fields)):
                    tmp = self._fresh("ins")
                    self._out(f"{tmp} = llvm.insertvalue {v}, {res}[{i}] : {mlir_ty}")
                    res = tmp
            return res, nm

        if kind == "Closure":
            # Closures are not directly GPU-executable; emit a warning comment.
            # GPU kernels must use only flat functions (no closures, no fat pointers).
            self._out("// closure in GPU context: use @device fn instead of closure")
            return "%closure_unsupported", "void"

        if kind == "Call":
            return self._emit_call(e, scope)

        self._out(f"// unknown expr kind {kind}")
        return self._fresh("unk"), "i32"

    # ── literal emission ──────────────────────────────────────────────────────

    def _emit_lit(self, e):
        res = self._fresh("c")
        lty = e.lty
        if lty in ("int_lit", "i32"):
            self._out(f"{res} = arith.constant {e.val} : i32")
            return res, "i32"
        if lty in ("i64", "u64"):
            self._out(f"{res} = arith.constant {e.val} : i64")
            return res, lty
        if lty in ("float_lit", "f32"):
            self._out(f"{res} = arith.constant {e.val} : f32")
            return res, "f32"
        if lty == "f64":
            self._out(f"{res} = arith.constant {e.val} : f64")
            return res, "f64"
        if lty == "bf16":
            self._out(f"{res} = arith.constant {e.val} : bf16")
            return res, "bf16"
        if lty == "bool":
            bval = "true" if e.val == "true" else "false"
            self._out(f"{res} = arith.constant {bval} : i1")
            return res, "bool"
        self._out(f"{res} = arith.constant {e.val} : i32  // fallback for {lty}")
        return res, "i32"

    # ── binary op emission ────────────────────────────────────────────────────

    def _emit_bin(self, e, scope):
        lt, _ = self._emit_expr(e.l, scope)
        rt, _ = self._emit_expr(e.r, scope)
        ty = getattr(e.l, "ty", None) or getattr(e.r, "ty", None) or "i32"
        res = self._fresh("b")

        # ── posit ops ──────────────────────────────────────────────────────
        if _is_posit(ty):
            if e.op in POSIT_MLIR_OPS:
                sym = POSIT_MLIR_OPS[e.op]
                self._out(f"{res} = func.call @{sym}({lt}, {rt}) : (i32, i32) -> i32")
                return res, ty
            # comparison: decode both to f64 first
            lf, rf = self._fresh("pf"), self._fresh("pf")
            self._out(f"{lf} = func.call @zag_p32_to_f64({lt}) : (i32) -> f64")
            self._out(f"{rf} = func.call @zag_p32_to_f64({rt}) : (i32) -> f64")
            pred = _cmp_pred_f(e.op)
            self._out(f"{res} = arith.cmpf {pred}, {lf}, {rf} : f64")
            return res, "bool"

        # ── LNS ops ───────────────────────────────────────────────────────
        if _is_lns(ty):
            if e.op in LNS_MLIR_OPS:
                sym = LNS_MLIR_OPS[e.op]
                self._out(f"{res} = func.call @{sym}({lt}, {rt}) : (i32, i32) -> i32")
                return res, ty
            # comparison: decode to f32 first
            lf, rf = self._fresh("lf"), self._fresh("lf")
            self._out(f"{lf} = func.call @zag_l32_to_f32({lt}) : (i32) -> f32")
            self._out(f"{rf} = func.call @zag_l32_to_f32({rt}) : (i32) -> f32")
            pred = _cmp_pred_f(e.op)
            self._out(f"{res} = arith.cmpf {pred}, {lf}, {rf} : f32")
            return res, "bool"

        # ── VSA ops ───────────────────────────────────────────────────────
        if is_vsa_type(ty):
            n = vsa_dim(ty)
            vty = f"vector<{n}xi1>"
            if e.op == "^":   # VSA bind = XOR
                self._out(f"{res} = arith.xori {lt}, {rt} : {vty}")
            elif e.op == "|": # VSA bundle (OR approximation; proper bundling needs popcount)
                self._out(f"{res} = arith.ori {lt}, {rt} : {vty}")
            else:
                self._out(f"{res} = arith.xori {lt}, {rt} : {vty}  // fallback for {e.op}")
            return res, ty

        # ── mx_fp8 ────────────────────────────────────────────────────────
        if ty == "mx_fp8":
            # Upcast to f32, op, downcast (hardware does this in block-scaled GEMM)
            lu, ru = self._fresh("fp32"), self._fresh("fp32")
            self._out(f"{lu} = arith.extf {lt} : f8E4M3FN to f32")
            self._out(f"{ru} = arith.extf {rt} : f8E4M3FN to f32")
            mid = self._fresh("m")
            self._out(f"{mid} = arith.{_float_arith(e.op)} {lu}, {ru} : f32")
            self._out(f"{res} = arith.truncf {mid} : f32 to f8E4M3FN")
            return res, "mx_fp8"

        # ── standard float ────────────────────────────────────────────────
        if _is_float(ty):
            mty = self._mtype(ty)
            if e.op in ("+", "-", "*", "/"):
                self._out(f"{res} = arith.{_float_arith(e.op)} {lt}, {rt} : {mty}")
                return res, ty
            pred = _cmp_pred_f(e.op)
            self._out(f"{res} = arith.cmpf {pred}, {lt}, {rt} : {mty}")
            return res, "bool"

        # ── standard integer ──────────────────────────────────────────────
        mty = self._mtype(ty)
        if e.op == "+":  self._out(f"{res} = arith.addi {lt}, {rt} : {mty}")
        elif e.op == "-": self._out(f"{res} = arith.subi {lt}, {rt} : {mty}")
        elif e.op == "*": self._out(f"{res} = arith.muli {lt}, {rt} : {mty}")
        elif e.op == "/": self._out(f"{res} = arith.divsi {lt}, {rt} : {mty}")
        elif e.op == "%": self._out(f"{res} = arith.remsi {lt}, {rt} : {mty}")
        elif e.op in ("==", "!=", "<", ">", "<=", ">="):
            pred = _cmp_pred_i(e.op)
            self._out(f"{res} = arith.cmpi {pred}, {lt}, {rt} : {mty}")
            return res, "bool"
        elif e.op == "&&":
            self._out(f"{res} = arith.andi {lt}, {rt} : i1")
            return res, "bool"
        elif e.op == "||":
            self._out(f"{res} = arith.ori {lt}, {rt} : i1")
            return res, "bool"
        else:
            self._out(f"// unsupported op {e.op}")
        return res, ty

    # ── call emission ─────────────────────────────────────────────────────────

    def _emit_call(self, e, scope):
        import types as _t
        callee = e.callee
        # Resolve callee name
        cname = None
        if hasattr(callee, 'name'):
            cname = e.inst_name or callee.name

        # GPU thread/block index intrinsics
        if cname in ("@gpuThreadIdx", "@gpuBlockIdx", "@gpuBlockDim", "@gpuGridDim"):
            dim_val, _ = self._emit_expr(e.args[0], scope)
            # Try to extract literal dimension
            dim_lit = _extract_int_lit(e.args[0])
            dim_str = GPU_DIM_NAMES.get(dim_lit, "x")
            intrinsic = {
                "@gpuThreadIdx": "gpu.thread_id",
                "@gpuBlockIdx":  "gpu.block_id",
                "@gpuBlockDim":  "gpu.block_dim",
                "@gpuGridDim":   "gpu.grid_dim",
            }[cname]
            res = self._fresh("tid")
            self._out(f"{res} = {intrinsic} {dim_str} : index")
            cast = self._fresh("cast")
            self._out(f"{cast} = arith.index_cast {res} : index to i32")
            return cast, "i32"

        if cname == "@gpuSyncThreads":
            self._out("gpu.barrier")
            return "", "void"

        # Posit cast builtins
        if cname == "@floatToPosit":
            arg, _ = self._emit_expr(e.args[0], scope)
            res = self._fresh("p")
            self._out(f"{res} = func.call @zag_f64_to_p32({arg}) : (f64) -> i32")
            return res, "p32"
        if cname == "@positToFloat":
            arg, _ = self._emit_expr(e.args[0], scope)
            res = self._fresh("f")
            self._out(f"{res} = func.call @zag_p32_to_f64({arg}) : (i32) -> f64")
            return res, "f64"

        # Host-side GPU memory: @gpuAlloc returns a f32 slice in GPU address space
        if cname == "@gpuAlloc":
            n, _ = self._emit_expr(e.args[0], scope)
            res = self._fresh("gbuf")
            self._out(f"{res} = gpu.alloc({n}) : memref<?xf32, 1>")
            return res, "[]f32"
        if cname == "@gpuFree":
            buf, bty = self._emit_expr(e.args[0], scope)
            elem = bty[2:] if bty.startswith("[]") else "f32"
            self._out(f"gpu.dealloc {buf} : memref<?x{self._mtype(elem)}, 1>")
            return "", "void"

        # MX cast builtins
        if cname == "@floatToMxFp8":
            arg, _ = self._emit_expr(e.args[0], scope)
            res = self._fresh("mx")
            self._out(f"{res} = arith.truncf {arg} : f32 to f8E4M3FN")
            return res, "mx_fp8"
        if cname == "@mxFp8ToFloat":
            arg, _ = self._emit_expr(e.args[0], scope)
            res = self._fresh("f32")
            self._out(f"{res} = arith.extf {arg} : f8E4M3FN to f32")
            return res, "f32"

        # LNS cast builtins
        if cname == "@floatToLog":
            arg, _ = self._emit_expr(e.args[0], scope)
            res = self._fresh("l")
            self._out(f"{res} = func.call @zag_f32_to_l32({arg}) : (f32) -> i32")
            return res, "l32"
        if cname == "@logToFloat":
            arg, _ = self._emit_expr(e.args[0], scope)
            res = self._fresh("f")
            self._out(f"{res} = func.call @zag_l32_to_f32({arg}) : (i32) -> f32")
            return res, "f32"

        # print_* builtins — extern C functions on host, emit as func.call
        if cname and cname.startswith("print_"):
            arg_vals = [self._emit_expr(a, scope) for a in e.args]
            arg_strs = ", ".join(v for v, _ in arg_vals)
            arg_type_strs = ", ".join(self._mtype(zty) for _, zty in arg_vals)
            self._out(f"func.call @{cname}({arg_strs}) : ({arg_type_strs}) -> ()")
            return "", "void"

        # @gpuLaunch(gx, gy, gz, bx, by, bz) — launches the last @kernel defined in scope.
        # In a later phase, pass the kernel fn as a first-class value; for now we emit a
        # gpu.launch comment so the .mlir is readable and mlir-opt can be given the full
        # launch manually.
        if cname == "@gpuLaunch":
            args_vals = [self._emit_expr(a, scope) for a in e.args]
            if len(args_vals) >= 6:
                gx, gy, gz = args_vals[0][0], args_vals[1][0], args_vals[2][0]
                bx, by, bz = args_vals[3][0], args_vals[4][0], args_vals[5][0]
                extra = ", ".join(f"{v} : {self._mtype(zty)}" for v, zty in args_vals[6:])
                self._out(f"// gpu.launch_func @zag_kernels::<kernel>")
                self._out(f"//     blocks in ({gx}, {gy}, {gz})")
                self._out(f"//     threads in ({bx}, {by}, {bz})")
                if extra:
                    self._out(f"//     args({extra})")
            else:
                self._out("// @gpuLaunch: insufficient args (need gx,gy,gz,bx,by,bz)")
            return "", "void"

        # Standard named function call
        arg_vals = [self._emit_expr(a, scope) for a in e.args]
        arg_strs = ", ".join(v for v, _ in arg_vals)
        arg_type_strs = ", ".join(self._mtype(zty) for _, zty in arg_vals)

        if cname and cname in self.sema.fns:
            f_decl = self.sema.fns[cname]
            ret_ty = f_decl.ret
            mret = self._mtype(ret_ty)
            if ret_ty == "void":
                self._out(f"func.call @{self._mangle(cname)}({arg_strs}) : ({arg_type_strs}) -> ()")
                return "", "void"
            res = self._fresh("r")
            self._out(f"{res} = func.call @{self._mangle(cname)}({arg_strs}) : ({arg_type_strs}) -> {mret}")
            return res, ret_ty

        # Fat-pointer call (function value in a local)
        cv, cty = self._emit_expr(callee, scope)
        ret_ty = getattr(e, "ty", None) or "i32"
        res = self._fresh("r")
        self._out(f"{res} = func.call_indirect {cv}({arg_strs}) : ({arg_type_strs}) -> {self._mtype(ret_ty)}")
        return res, ret_ty

    # ── utility ───────────────────────────────────────────────────────────────

    def _mangle(self, name: str) -> str:
        return name.replace("[", "_").replace("]", "").replace(",", "_").replace("@", "")

    def _collect_mutated(self, stmts) -> set:
        out = set()
        def ws(s):
            n = type(s).__name__
            if n == "Assign":
                t = _varname(s.target)
                if t:
                    out.add(t)
            elif n == "If":
                for x in s.then: ws(x)
                for x in (s.els or []): ws(x)
            elif n == "While":
                for x in s.body: ws(x)
            elif n == "Switch":
                for _, _, body in s.arms:
                    for x in body: ws(x)
                for x in (s.els or []): ws(x)
        for s in stmts: ws(s)
        return out

    def _find_let_type(self, stmts, name: str) -> str | None:
        for s in stmts:
            n = type(s).__name__
            if n == "Let" and s.name == name:
                return s.dty or getattr(s.expr, "ty", None) or "i32"
        return None

    def _emit_header(self):
        target_comment = {
            "nvidia": "NVIDIA NVVM/CUDA (nvvm + gpu + llvm dialects)",
            "amd":    "AMD ROCDL/HIP (rocdl + gpu + llvm dialects)",
            "vulkan": "Vulkan SPIR-V portability fallback (spirv dialect)",
        }.get(self.target, self.target)
        self._out(f"// Zag MLIR — generated by zagc gpu backend")
        self._out(f"// Target: {target_comment}")
        self._out(f"//")
        self._out(f"// Lower with:")
        if self.target == "nvidia":
            self._out(f"//   mlir-opt --pass-pipeline='builtin.module(gpu-kernel-outlining,")
            self._out(f"//     convert-gpu-to-nvvm,gpu-to-llvm,convert-func-to-llvm)' \\")
            self._out(f"//     | mlir-translate --mlir-to-llvmir | llc -march=nvptx64")
        elif self.target == "amd":
            self._out(f"//   mlir-opt --pass-pipeline='builtin.module(gpu-kernel-outlining,")
            self._out(f"//     convert-gpu-to-rocdl,gpu-to-llvm,convert-func-to-llvm)' \\")
            self._out(f"//     | mlir-translate --mlir-to-llvmir")
        elif self.target == "vulkan":
            self._out(f"//   mlir-opt --convert-gpu-to-spirv --serialize-spirv \\")
            self._out(f"//     | spirv-dis  (or load the .spv binary directly)")
        self._out(f"")


# ── helper classes/functions ──────────────────────────────────────────────────

class _Var_like:
    """Dummy to avoid importing the AST classes here."""
    def __instancecheck__(self, inst):
        return type(inst).__name__ == "Var"

def _varname(expr) -> str | None:
    if type(expr).__name__ == "Var":
        return expr.name
    return None

def _extract_int_lit(expr) -> int | None:
    if type(expr).__name__ == "Lit":
        try:
            return int(expr.val)
        except (ValueError, AttributeError):
            return None
    return None

def _extract_fn_name(expr) -> str:
    if type(expr).__name__ == "Var":
        return expr.name
    return "kernel"

def _float_arith(op: str) -> str:
    return {"+" : "addf", "-": "subf", "*": "mulf", "/": "divf"}.get(op, "addf")

def _cmp_pred_f(op: str) -> str:
    return {"==": "oeq", "!=": "one", "<": "olt", ">": "ogt",
            "<=": "ole", ">=": "oge"}.get(op, "oeq")

def _cmp_pred_i(op: str) -> str:
    return {"==": "eq", "!=": "ne", "<": "slt", ">": "sgt",
            "<=": "sle", ">=": "sge"}.get(op, "eq")


# ── standalone entry point ────────────────────────────────────────────────────

def emit_mlir(sema, target: str = "nvidia") -> str:
    em = MLIREmitter(sema, target)
    return em.emit_module()
