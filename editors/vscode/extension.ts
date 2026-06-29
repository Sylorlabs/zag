// editors/vscode/extension.ts — VS Code extension for the Zag language.
//
// Starts the Zag LSP server binary and connects it to VS Code via the
// vscode-languageclient library.  The server binary is located by checking:
//   1. The zag.serverPath workspace setting
//   2. The PATH environment variable (binary named "znc-lsp")
//
// Provides: diagnostics, completion, hover, go-to-definition, rename.

import * as path from "path";
import { workspace, ExtensionContext, window, OutputChannel } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: ExtensionContext): void {
  const config = workspace.getConfiguration("zag");
  const serverBin: string = config.get<string>("serverPath") ?? "znc-lsp";

  const serverOptions: ServerOptions = {
    command: serverBin,
    args: [],
    transport: TransportKind.stdio,
    options: {
      // Inherit environment so PATH-based lookup works.
      env: process.env,
    },
  };

  const clientOptions: LanguageClientOptions = {
    // Register the server for Zag (.zag) documents.
    documentSelector: [{ scheme: "file", language: "zag" }],
    synchronize: {
      // Notify the server if zag.mod changes in the workspace.
      fileEvents: workspace.createFileSystemWatcher("**/zag.mod"),
    },
    outputChannelName: "Zag Language Server",
    traceOutputChannel: window.createOutputChannel("Zag LSP Trace"),
  };

  client = new LanguageClient(
    "zag-lang",
    "Zag Language Server",
    serverOptions,
    clientOptions
  );

  // Start the client. This also starts the server process.
  client.start();

  context.subscriptions.push({
    dispose: () => {
      if (client) {
        client.stop();
        client = undefined;
      }
    },
  });
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}
