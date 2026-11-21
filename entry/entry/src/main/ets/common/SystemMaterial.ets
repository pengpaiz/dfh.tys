import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

/** 组件级沉浸材质（uiMaterial）自 API 26 起才提供。 */
const IMMERSIVE_MATERIAL_API = 26;

/**
 * 返回「薄」沉浸材质；在低版本设备上一律返回 undefined。
 *
 * 低版本（API < 26）设备不存在 uiMaterial 模块，直接写
 * uiMaterial.ImmersiveStyle.THIN 会在首屏渲染时抛
 * "Cannot read property THIN of undefined"，进程随即被 JS 错误杀死。
 * systemMaterial 形参类型为 SystemUiMaterial | undefined，传 undefined 即不启用材质。
 */
export function immersiveThinMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  if (deviceInfo.sdkApiVersion < IMMERSIVE_MATERIAL_API) {
    return undefined;
  }
  if (!uiMaterial.isImmersiveMaterialSupported()) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    applyShadow: true,
    interactive: true
  });
}
