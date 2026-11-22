import * as esbuild from 'esbuild';
import path from 'node:path';
await esbuild.build({entryPoints:['world_export_f1.ts'],bundle:true,platform:'node',format:'cjs',outfile:'world_export_f1.cjs',external:['@napi-rs/canvas'],nodePaths:[path.resolve('node_modules')],logLevel:'warning'});
