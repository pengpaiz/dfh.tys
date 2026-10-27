/*
 * 测试用 ESM loader：让 Node 能解析 ArkTS 风格的无扩展名相对导入（自动补 .ts）。
 * 用法：node --import ./tools/robot36/loader.mjs tools/robot36/test-p0.ts
 */
import { existsSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, resolve as resolvePath } from 'node:path';

export async function resolve(specifier, context, nextResolve) {
  if ((specifier.startsWith('./') || specifier.startsWith('../')) && !/\.[a-z]+$/i.test(specifier)) {
    const parentPath = context.parentURL ? fileURLToPath(context.parentURL) : process.cwd();
    const candidate = resolvePath(dirname(parentPath), specifier + '.ts');
    if (existsSync(candidate)) {
      return { url: pathToFileURL(candidate).href, shortCircuit: true };
    }
  }
  return nextResolve(specifier, context);
}