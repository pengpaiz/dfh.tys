/*
 * Look4Sat. Shared app settings (station, forecast params) across tabs.
 * Persisted in AppStorage so values survive tab switches and re-render reactively.
 */

import { SatGeoPos } from '../domain/predict/GeoPos';
import { positionToQth } from '../domain/qth/QthConverter';

const K_LAT = 'station_latitude';
const K_LON = 'station_longitude';
const K_ALT = 'station_altitude';
const K_QTH = 'station_qth';
const K_MIN_ELEV = 'settings_min_elevation';
const K_WINDOW_H = 'settings_window_hours';
const K_SORT = 'settings_pass_sort';
const K_STATION_VER = 'station_version';
/** 站址是否由用户手动设置过：是则启动静默定位不再覆盖 */
const K_STATION_MANUAL = 'station_manual';
/** 自定义数据源 URL（空 = 使用内置离线数据） */
const K_TLE_URL = 'settings_custom_tle_url';
const K_TRANS_URL = 'settings_custom_transponder_url';
/** 数据源使用情况：最近一次成功更新用的地址/时间，以及镜像、自定义地址各自最近成功时间 */
const K_SRC_LAST_URL = 'data_source_last_url';
const K_SRC_LAST_TIME = 'data_source_last_time';
const K_SRC_MIRROR_TIME = 'data_source_mirror_time';
const K_SRC_CUSTOM_TIME = 'data_source_custom_time';
const K_SRC_CUSTOM_RESULT = 'data_source_custom_result';

/** 自定义地址最近一次使用结果 */
export const CUSTOM_RESULT_NONE = 0;
export const CUSTOM_RESULT_OK = 1;
export const CUSTOM_RESULT_FAIL = 2;

export enum PassSortMode {
  BY_SATELLITE = 0,
  BY_TIME = 1
}

export const WINDOW_PRESETS: number[] = [12, 24, 48];

export class AppSettings {
  static init(): void {
    PersistentStorage.persistProp(K_LAT, 48.2);
    PersistentStorage.persistProp(K_LON, 16.37);
    PersistentStorage.persistProp(K_ALT, 0);
    PersistentStorage.persistProp(K_MIN_ELEV, 5);
    PersistentStorage.persistProp(K_WINDOW_H, 24);
    PersistentStorage.persistProp(K_SORT, PassSortMode.BY_SATELLITE);
    PersistentStorage.persistProp(K_QTH, '');
    PersistentStorage.persistProp(K_TLE_URL, '');
    PersistentStorage.persistProp(K_TRANS_URL, '');
    PersistentStorage.persistProp(K_STATION_MANUAL, false);
    PersistentStorage.persistProp(K_SRC_LAST_URL, '');
    PersistentStorage.persistProp(K_SRC_LAST_TIME, 0);
    PersistentStorage.persistProp(K_SRC_MIRROR_TIME, 0);
    PersistentStorage.persistProp(K_SRC_CUSTOM_TIME, 0);
    PersistentStorage.persistProp(K_SRC_CUSTOM_RESULT, CUSTOM_RESULT_NONE);
    if (AppStorage.get<number>(K_STATION_VER) === undefined) {
      AppStorage.setOrCreate<number>(K_STATION_VER, 0);
    }
  }

  /** 站址变更版本号：设置页据此刷新已显示的经纬度/海拔，避免显示过期值。 */
  static getStationVersion(): number {
    return AppStorage.get<number>(K_STATION_VER) ?? 0;
  }

  static getStation(): SatGeoPos {
    return new SatGeoPos(
      AppStorage.get<number>(K_LAT) ?? 48.2,
      AppStorage.get<number>(K_LON) ?? 16.37,
      AppStorage.get<number>(K_ALT) ?? 0,
      'station'
    );
  }

  /** [manual] 为 true 表示用户手动设定，启动静默定位不再覆盖该站址。 */
  static setStation(lat: number, lon: number, alt: number, manual: boolean = false): void {
    AppStorage.setOrCreate<number>(K_LAT, lat);
    AppStorage.setOrCreate<number>(K_LON, lon);
    AppStorage.setOrCreate<number>(K_ALT, alt);
    if (manual) {
      AppStorage.setOrCreate<boolean>(K_STATION_MANUAL, true);
    }
    const qth = positionToQth(lat, lon);
    if (qth !== null) {
      AppStorage.setOrCreate<string>(K_QTH, qth);
    }
    AppStorage.setOrCreate<number>(K_STATION_VER, AppSettings.getStationVersion() + 1);
  }

  /** 恢复默认站址并清除"用户手动设定"标记（供"清除本机数据"使用）。 */
  static resetStation(): void {
    AppSettings.setStation(48.2, 16.37, 0);
    AppStorage.setOrCreate<boolean>(K_STATION_MANUAL, false);
  }

  /** 用户是否手动设定过站址。 */
  static isStationManual(): boolean {
    return AppStorage.get<boolean>(K_STATION_MANUAL) ?? false;
  }

  /** 自定义 TLE 数据源；返回空串表示未设置（用内置离线数据）。 */
  static getCustomTleUrl(): string {
    return AppStorage.get<string>(K_TLE_URL) ?? '';
  }

  static setCustomTleUrl(url: string): void {
    AppStorage.setOrCreate<string>(K_TLE_URL, url.trim());
  }

  /** 自定义转发器 JSON 数据源；返回空串表示未设置。 */
  static getCustomTransponderUrl(): string {
    return AppStorage.get<string>(K_TRANS_URL) ?? '';
  }

  static setCustomTransponderUrl(url: string): void {
    AppStorage.setOrCreate<string>(K_TRANS_URL, url.trim());
  }

  // ---- 数据源使用情况（供设置页显示"当前模式 / 各自更新时间"）----

  /** 记录一次成功更新：[isMirror]/[isCustom] 表示命中的是内置离线数据还是用户自定义地址。
   *  [timestamp] 传入 0 表示用当前时间；导入内置快照时用快照自带的抓取时间。 */
  static recordDataSourceResult(url: string, isMirror: boolean, isCustom: boolean, timestamp: number = 0): void {
    const now = timestamp > 0 ? timestamp : Date.now();
    AppStorage.setOrCreate<string>(K_SRC_LAST_URL, url);
    AppStorage.setOrCreate<number>(K_SRC_LAST_TIME, now);
    if (isMirror) {
      AppStorage.setOrCreate<number>(K_SRC_MIRROR_TIME, now);
    }
    if (isCustom) {
      AppStorage.setOrCreate<number>(K_SRC_CUSTOM_TIME, now);
    }
  }

  /** 记录自定义地址最近一次使用的结果（成功/失败），失败也会被记下来。 */
  static recordCustomResult(ok: boolean): void {
    AppStorage.setOrCreate<number>(K_SRC_CUSTOM_RESULT, ok ? CUSTOM_RESULT_OK : CUSTOM_RESULT_FAIL);
  }

  static getCustomResult(): number {
    return AppStorage.get<number>(K_SRC_CUSTOM_RESULT) ?? CUSTOM_RESULT_NONE;
  }

  static getLastSourceUrl(): string {
    return AppStorage.get<string>(K_SRC_LAST_URL) ?? '';
  }

  static getLastSourceTime(): number {
    return AppStorage.get<number>(K_SRC_LAST_TIME) ?? 0;
  }

  static getMirrorUpdateTime(): number {
    return AppStorage.get<number>(K_SRC_MIRROR_TIME) ?? 0;
  }

  static getCustomUpdateTime(): number {
    return AppStorage.get<number>(K_SRC_CUSTOM_TIME) ?? 0;
  }

  /** 时间戳格式化为 yyyy-MM-dd HH:mm；0 表示还没有成功记录。 */
  static formatTime(ms: number): string {
    if (ms <= 0) {
      return '—';
    }
    const d = new Date(ms);
    const p2 = (v: number): string => v < 10 ? `0${v}` : `${v}`;
    return `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`;
  }

  static getMinElevation(): number {
    return AppStorage.get<number>(K_MIN_ELEV) ?? 5;
  }

  static setMinElevation(v: number): void {
    AppStorage.setOrCreate<number>(K_MIN_ELEV, v);
  }

  static getWindowHours(): number {
    return AppStorage.get<number>(K_WINDOW_H) ?? 48;
  }

  static setWindowHours(v: number): void {
    AppStorage.setOrCreate<number>(K_WINDOW_H, v);
  }

  static getSortMode(): number {
    return AppStorage.get<number>(K_SORT) ?? PassSortMode.BY_TIME;
  }

  static setSortMode(mode: number): void {
    AppStorage.setOrCreate<number>(K_SORT, mode);
  }
}