/*
 * Look4Sat. 过境预报（48h 窗口）的共享缓存。
 *
 * 目的：过境页原来每次重算都对**每颗**已选星同步跑一遍 getPasses(48h)，
 * 选的星一多，启动/切页就会出现长时间卡顿。
 * 这里把「单颗星 48h 过境」缓存起来：
 * - 只有新选中的星需要补算，其余直接命中；
 * - 窗口(12/24/48h)与仰角门槛只影响显示过滤，不影响这里的计算，所以整份缓存通吃；
 * - 缓存项自带有效性标识（数据版本 + 站址 + 小时桶），逐项判断过期，
 *   不再因为签名变化就整表 clear()（§5/§6/§29）；
 * - 有上限，超出后淘汰最久未使用项（§28）。
 */

import { SatOrbitalData } from './OrbitalData';
import { SatGeoPos } from './GeoPos';
import { SatPassEvent, SatPassFinder } from './SatPassFinder';
import { createOrbitalObject } from './OrbitalFactory';
import { AppSettings } from '../../common/AppSettings';

/** 统一按最长窗口计算，短窗口只在显示时过滤 */
export const PASS_CACHE_HOURS = 48;
/** 缓存上限：超出后淘汰最久未使用的一项 */
const MAX_CACHED_SATS = 240;
/** 时间桶长度：1 小时（等于每项最长保鲜时间） */
const HOUR_MS = 3600000;

/** 单颗星的 48h 过境缓存 + 它自己的有效性标识。 */
class CachedPasses {
  name: string = '';
  passes: SatPassEvent[] = [];
  dataVersion: number = -1;
  lat: number = 0;
  lon: number = 0;
  alt: number = 0;
  hourBucket: number = -1;

  constructor(name: string, passes: SatPassEvent[], dataVersion: number, station: SatGeoPos, hourBucket: number) {
    this.name = name;
    this.passes = passes;
    this.dataVersion = dataVersion;
    this.lat = station.latitude;
    this.lon = station.longitude;
    this.alt = station.altitude;
    this.hourBucket = hourBucket;
  }

  /** 与当前上下文一致才算有效。 */
  matches(dataVersion: number, station: SatGeoPos, hourBucket: number): boolean {
    return this.dataVersion === dataVersion
      && this.lat === station.latitude
      && this.lon === station.longitude
      && this.alt === station.altitude
      && this.hourBucket === hourBucket;
  }
}

export class PassCache {
  private static instanceValue: PassCache | null = null;
  private cache: Map<number, CachedPasses> = new Map<number, CachedPasses>();
  private finder: SatPassFinder = new SatPassFinder();
  /** 当前上下文（由 prepare() 刷新），用于逐项校验 */
  private dataVersion: number = -1;
  private station: SatGeoPos = new SatGeoPos(0, 0);
  private hourBucket: number = -1;

  static getInstance(): PassCache {
    if (PassCache.instanceValue === null) {
      PassCache.instanceValue = new PassCache();
    }
    return PassCache.instanceValue;
  }

  /** 刷新上下文：只登记"当前有效条件"，**不清空**缓存（旧项按需重算）。 */
  prepare(dataVersion: number): void {
    this.dataVersion = dataVersion;
    this.station = AppSettings.getStation();
    this.hourBucket = Math.floor(Date.now() / HOUR_MS);
  }

  private lookup(catnum: number): CachedPasses | null {
    const c = this.cache.get(catnum);
    if (c === undefined || !c.matches(this.dataVersion, this.station, this.hourBucket)) {
      return null;
    }
    // 命中后移到末尾 = 最近使用（LRU）
    this.cache.delete(catnum);
    this.cache.set(catnum, c);
    return c;
  }

  has(catnum: number): boolean {
    return this.lookup(catnum) !== null;
  }

  nameOf(catnum: number): string {
    const c = this.lookup(catnum);
    return c === null ? '' : c.name;
  }

  passesOf(catnum: number): SatPassEvent[] {
    const c = this.lookup(catnum);
    return c === null ? [] : c.passes;
  }

  /** 星在库里找不到时也记一笔空缓存，避免反复重试。 */
  markMissing(catnum: number): void {
    this.put(catnum, '', []);
  }

  /** 单颗星计算并入缓存（同步，调用方负责让帧）。 */
  computeOne(catnum: number, satData: SatOrbitalData, station: SatGeoPos, now: number): void {
    let passes: SatPassEvent[] = [];
    try {
      const obj = createOrbitalObject(satData);
      passes = this.finder.getPasses(obj, station, now, PASS_CACHE_HOURS);
    } catch (e) {
      passes = [];
    }
    this.put(catnum, satData.name, passes);
  }

  private put(catnum: number, name: string, passes: SatPassEvent[]): void {
    this.cache.set(catnum, new CachedPasses(name, passes, this.dataVersion, this.station, this.hourBucket));
    while (this.cache.size > MAX_CACHED_SATS) {
      const oldest = this.cache.keys().next();
      if (oldest.done === true) {
        break;
      }
      this.cache.delete(oldest.value);
    }
  }

  /** 数据整体替换（下载/导入新 TLE）时调用。 */
  clear(): void {
    this.cache.clear();
  }

  size(): number {
    return this.cache.size;
  }
}
