/*
 * Look4Sat. 已解析轨道对象（SGP4/SDP4）的全局复用缓存。
 *
 * createOrbitalObject() 会重新解析 TLE 并做 SGP4/深空初始化，属于较贵的操作。
 * 过境页、日历、地图、详情页都需要同一颗星的轨道对象，之前各自 new 一份，
 * 同一颗星被反复初始化。这里按「NORAD 号 + TLE 历元」缓存，
 * 只有 TLE 真正更新（历元变化）时才重新创建。
 *
 * 处理掉的内容：
 * - §16 避免重复解析 TLE
 * - §17 OrbitalObject 应该复用
 * - §28 缓存有上限（LRU 淘汰最久未使用的）
 */

import { SatOrbitalData } from './OrbitalData';
import { SatOrbitalObject } from './OrbitalObject';

/** 缓存上限：超出后淘汰最久未使用的一项 */
const MAX_CACHED_OBJECTS = 300;

export class OrbitalObjectCache {
  private static instanceValue: OrbitalObjectCache | null = null;
  private cache: Map<string, SatOrbitalObject> = new Map<string, SatOrbitalObject>();
  /** 按 NORAD 号记录当前有效的 key，便于快速命中 */
  private keyByCat: Map<number, string> = new Map<number, string>();

  static getInstance(): OrbitalObjectCache {
    if (OrbitalObjectCache.instanceValue === null) {
      OrbitalObjectCache.instanceValue = new OrbitalObjectCache();
    }
    return OrbitalObjectCache.instanceValue;
  }

  /** TLE 变化（历元/轨道根数）即视为不同对象。 */
  private static keyOf(data: SatOrbitalData): string {
    return `${data.catnum}|${data.epoch}|${data.isDeepSpace ? 'd' : 'n'}`;
  }

  get(data: SatOrbitalData): SatOrbitalObject | null {
    const key = OrbitalObjectCache.keyOf(data);
    const cached = this.cache.get(key);
    if (cached === undefined) {
      return null;
    }
    // 命中后移到末尾 = 最近使用（LRU）
    this.cache.delete(key);
    this.cache.set(key, cached);
    return cached;
  }

  put(data: SatOrbitalData, obj: SatOrbitalObject): void {
    const key = OrbitalObjectCache.keyOf(data);
    this.cache.set(key, obj);
    this.keyByCat.set(data.catnum, key);
    while (this.cache.size > MAX_CACHED_OBJECTS) {
      const oldest = this.cache.keys().next();
      if (oldest.done === true) {
        break;
      }
      const oldKey: string = oldest.value;
      this.cache.delete(oldKey);
      const catStr = oldKey.split('|')[0];
      const cat = Number(catStr);
      if (this.keyByCat.get(cat) === oldKey) {
        this.keyByCat.delete(cat);
      }
    }
  }

  /** 数据整体替换（下载/导入新 TLE）后调用，避免旧对象长期占用内存。 */
  clear(): void {
    this.cache.clear();
    this.keyByCat.clear();
  }

  size(): number {
    return this.cache.size;
  }
}
