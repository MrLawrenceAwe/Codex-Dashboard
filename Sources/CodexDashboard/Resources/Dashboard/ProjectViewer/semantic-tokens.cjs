// This helper processes file text on stdin. It loads only the editor toolchains
// selected by Dashboard and never loads a project's JavaScript or plugins.
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

// SourceKit's semantic stream can omit the names at their declarations.
const swiftDeclarationTypes = {
  5: 'class', 6: 'method', 7: 'property', 8: 'property', 9: 'method',
  10: 'enum', 11: 'interface', 12: 'function', 13: 'variable', 14: 'variable',
  23: 'struct', 26: 'typeParameter',
};

function typeScriptTokens(modulePath, fileName, text) {
  const ts = require(modulePath);
  const service = ts.createLanguageService({
    getCompilationSettings: () => ({ allowJs: true, jsx: ts.JsxEmit.Preserve, noLib: true, noResolve: true }),
    getScriptFileNames: () => [fileName],
    getScriptVersion: () => '1',
    getScriptSnapshot: file => file === fileName ? ts.ScriptSnapshot.fromString(text) : undefined,
    getCurrentDirectory: () => '/',
    getDefaultLibFileName: () => '',
    fileExists: file => file === fileName,
    readFile: file => file === fileName ? text : undefined,
  });
  const types = ['class', 'enum', 'interface', 'namespace', 'typeParameter', 'type', 'parameter',
    'variable', 'enumMember', 'property', 'function', 'method'];
  const tokens = [];
  try {
    const { spans } = service.getEncodedSemanticClassifications(
      fileName, { start: 0, length: text.length }, ts.SemanticClassificationFormat.TwentyTwenty);
    for (let i = 0; i < spans.length; i += 3) {
      const type = types[(spans[i + 2] >> 8) - 1];
      if (type) tokens.push({ offset: spans[i], length: spans[i + 1], type });
    }
  } finally { service.dispose(); }
  return tokens;
}

function swiftTokens(fileName, text) {
  return new Promise(resolve => {
    const server = spawn('/usr/bin/sourcekit-lsp', [], { stdio: ['pipe', 'pipe', 'ignore'] });
    const uri = pathToFileURL(fileName).href;
    const starts = [0];
    for (let i = 0; i < text.length; i++) if (text[i] === '\n') starts.push(i + 1);
    let legend = [];
    let buffer = Buffer.alloc(0);
    let finished = false;
    const tokens = new Map();
    const addDeclaration = symbol => {
      const type = swiftDeclarationTypes[symbol.kind];
      const start = symbol.selectionRange?.start;
      if (type && start && starts[start.line] !== undefined) {
        const name = symbol.name.split('(')[0];
        const offset = starts[start.line] + start.character;
        if (name && text.startsWith(name, offset)) {
          tokens.set(offset, { offset, length: name.length, type });
        }
      }
      for (const child of symbol.children || []) addDeclaration(child);
    };
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(deadline);
      process.off('SIGTERM', finish);
      server.stdin.destroy();
      server.stdout.destroy();
      server.kill();
      resolve([...tokens.values()]);
    };
    const deadline = setTimeout(finish, 12000);
    process.once('SIGTERM', finish);
    const send = (method, params, id) => {
      const body = JSON.stringify({ jsonrpc: '2.0', method, params, id });
      server.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    };
    server.on('error', finish);
    server.on('exit', finish);
    server.stdin.on('error', finish);
    server.stdout.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      for (;;) {
        const headerEnd = buffer.indexOf('\r\n\r\n');
        if (headerEnd < 0) return;
        const length = Number(/Content-Length:\s*(\d+)/i.exec(buffer.subarray(0, headerEnd).toString())?.[1]);
        const end = headerEnd + 4 + length;
        if (!Number.isFinite(length)) { finish(); return; }
        if (buffer.length < end) return;
        const reply = JSON.parse(buffer.subarray(headerEnd + 4, end).toString());
        buffer = buffer.subarray(end);
        if (reply.id === 1) {
          legend = reply.result?.capabilities?.semanticTokensProvider?.legend?.tokenTypes || [];
          if (!reply.result) { finish(); return; }
          send('initialized', {});
          send('textDocument/didOpen', { textDocument: { uri, languageId: 'swift', version: 1, text } });
          send('textDocument/documentSymbol', { textDocument: { uri } }, 2);
        } else if (reply.id === 2) {
          for (const symbol of reply.result || []) addDeclaration(symbol);
          if (!legend.length) { finish(); return; }
          send('textDocument/semanticTokens/full', { textDocument: { uri } }, 3);
        } else if (reply.id === 3) {
          let line = 0, column = 0;
          const data = reply.result?.data || [];
          for (let i = 0; i + 4 < data.length; i += 5) {
            line += data[i];
            column = data[i] ? data[i + 1] : column + data[i + 1];
            if (starts[line] !== undefined && legend[data[i + 3]]) {
              const offset = starts[line] + column;
              tokens.set(offset, { offset, length: data[i + 2], type: legend[data[i + 3]] });
            }
          }
          finish();
          return;
        }
      }
    });
    send('initialize', {
      rootUri: null,
      workspaceFolders: [],
      capabilities: {
        general: { positionEncodings: ['utf-16'] },
        textDocument: {
          documentSymbol: { hierarchicalDocumentSymbolSupport: true },
          semanticTokens: {
            requests: { full: true },
            tokenTypes: [
              'namespace', 'type', 'class', 'enum', 'interface', 'struct', 'typeParameter', 'parameter',
              'variable', 'property', 'enumMember', 'function', 'method', 'macro', 'keyword', 'modifier',
              'comment', 'string', 'number', 'regexp', 'operator', 'decorator',
            ],
            tokenModifiers: ['declaration', 'definition', 'readonly', 'static'],
            formats: ['relative'],
          },
        },
      },
    }, 1);
  });
}

(async () => {
  const [engine, fileName, modulePath] = process.argv.slice(2);
  const text = fs.readFileSync(0, 'utf8');
  const tokens = engine === 'swift' ? await swiftTokens(fileName, text) : typeScriptTokens(modulePath, fileName, text);
  process.stdout.write(JSON.stringify(tokens));
})().catch(() => { process.exitCode = 1; });
