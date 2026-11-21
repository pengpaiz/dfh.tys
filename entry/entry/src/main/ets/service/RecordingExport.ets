/*
 * 录音导出：把沙盒里的 WAV 通过系统保存器写入用户选择的「下载」目录。
 *
 * HarmonyOS NEXT 普通应用不能静默创建/写入公共 Download 子目录，
 * 公共目录写入必须经过 DocumentViewPicker 由用户确认位置。
 */

import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/** 导出沙盒 WAV 到用户选择的下载位置；返回最终 URI，用户取消则返回空串。 */
export async function exportRecordingToDownload(
  context: common.UIAbilityContext,
  sandboxPath: string,
  fileName: string
): Promise<string> {
  const viewPicker = new picker.DocumentViewPicker(context);
  const opt = new picker.DocumentSaveOptions();
  opt.newFileNames = [fileName];
  opt.fileSuffixChoices = ['WAV|.wav'];
  const uris: string[] = await viewPicker.save(opt);
  if (uris === null || uris.length === 0) {
    return '';
  }
  let uri = uris[0];
  try {
    if (fs.statSync(uri).isDirectory()) {
      uri = `${uri}/${fileName}`;
    }
  } catch (e) {
    // stat 失败时按文件 uri 处理
  }
  const stat = fs.statSync(sandboxPath);
  const buf = new ArrayBuffer(stat.size);
  const src = fs.openSync(sandboxPath, fs.OpenMode.READ_ONLY);
  const read = fs.readSync(src.fd, buf);
  fs.closeSync(src);
  const dst = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  fs.writeSync(dst.fd, buf, { offset: 0, length: read });
  fs.closeSync(dst);
  return uri;
}
