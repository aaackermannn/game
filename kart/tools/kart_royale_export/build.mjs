import * as esbuild from 'esbuild';
import path from 'node:path';
await esbuild.build({entryPoints:['export.ts'],bundle:true,platform:'node',format:'esm',outfile:'export.mjs',nodePaths:[path.resolve('node_modules')],logLevel:'warning'});
