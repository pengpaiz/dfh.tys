/*
 * 统一日志开关（§11/§12）。
 *
 * Release 下 debug / info 全部静默，只保留 warn / error；
 * 需要排查时把 DEBUG 改成 true 即可，不必到处手动加删日志。
 * 注意：**高频路径（雷达逐帧、列表逐项）不要打日志**。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

/** 打开后输出 debug / info */
export const DEBUG: boolean = false;

const DOMAIN = 0x0001;

export class Logger {
  static debug(tag: string, msg: string): void {
    if (DEBUG) {
      hilog.debug(DOMAIN, tag, '%{public}s', msg);
    }
  }

  static info(tag: string, msg: string): void {
    if (DEBUG) {
      hilog.info(DOMAIN, tag, '%{public}s', msg);
    }
  }

  static warn(tag: string, msg: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', msg);
  }

  static error(tag: string, msg: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', msg);
  }
}
