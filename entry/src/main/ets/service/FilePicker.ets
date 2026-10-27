/*
 * 文件选择：用 DocumentViewPicker 选择本地音频（WAV 优先）。
 * 不申请任何权限；返回 URI 与显示名，由 Worker 侧读取。
 */

import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export interface PickedFile {
  uri: string;
  name: string;
}

export async function pickWavFile(context: common.UIAbilityContext): Promise<PickedFile | null> {
  const viewPicker = new picker.DocumentViewPicker(context);
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  options.fileSuffixFilters = ['.wav', '.WAV'];
  const uris = await viewPicker.select(options);
  if (uris === null || uris.length === 0) {
    return null;
  }
  const uri = uris[0];
  const parts = uri.split('/');
  return { uri, name: parts.length > 0 ? parts[parts.length - 1] : uri };
}