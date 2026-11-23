import * as esbuild from 'esbuild';
import path from 'node:path';
await esbuild.build({entryPoints:['world_export.ts'],bundle:true,platform:'node',format:'cjs',outfile:'world_export.cjs',external:['@napi-rs/canvas'],nodePaths:[path.resolve('node_modules')],logLevel:'warning'});
