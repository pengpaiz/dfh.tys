/*
 * Look4Sat. 日历 14 天预报的共享缓存。
 *
 * 目的：日历页需要「已选卫星 × 14 天」的过境结果，这个计算很贵。
 * 之前只在本页可见时才算，导致打开日历要等几秒。
 * 现在缓存提到单例里，由 App 根组件在启动后、以及选择/站址/数据变化时后台预热，
 * 日历页打开时直接汇总缓存即可（增量：新选中的星只补算它自己）。
 */

import { SatOrbitalData } from './OrbitalData';
import { SatGeoPos } from './GeoPos';
import { SatPassEvent, SatPassFinder } from './SatPassFinder';
import { SatOrbitalObject } from './OrbitalObject';
import { createOrbitalObject } from './OrbitalFactory';
import { SatelliteApp } from '../../common/SatelliteApp';
import { AppSettings } from '../../common/AppSettings';

/** 预报窗口天数 */
export const CAL_FORECAST_DAYS = 14;
/** 预热时每算完一颗星让出多久：给渲染留足帧，避免后台计算卡交互 */
const WARM_YIELD_MS = 32;
/** 首次预热前的等待：让启动首屏与入场动画先稳定下来 */
const WARM_START_DELAY_MS = 500;
/** 缓存上限：超出后淘汰最久未使用的一项（§28） */
const MAX_CACHED_FORECASTS = 240;

/** 单颗星的 14 天预报缓存（未按仰角过滤，过滤在汇总时按当前设置做）。 */
class CachedForecast {
  name: string = '';
  passes: SatPassEvent[] = [];

  constructor(name: string, passes: SatPassEvent[]) {
    this.name = name;
    this.passes = passes;
  }
}

/** 一次预热请求的参数（并发时保留最后一次，算完再补跑） */
class WarmRequest {
  cats: number[] = [];
  dataVersion: number = 0;
  station: SatGeoPos = new SatGeoPos(0, 0);
  now: number = 0;
  signature: string = '';

  constructor(cats: number[], dataVersion: number, station: SatGeoPos, now: number, signature: string) {
    this.cats = cats;
    this.dataVersion = dataVersion;
    this.station = station;
    this.now = now;
    this.signature = signature;
  }
}

export class CalendarForecast {
  private static instanceValue: CalendarForecast | null = null;
  private static firstWarmDone: boolean = false;
  private cache: Map<number, CachedForecast> = new Map<number, CachedForecast>();
  private signature: string = '';
  private finder: SatPassFinder = new SatPassFinder();
  private warming: boolean = false;
  private pendingReq: WarmRequest | null = null;

  static getInstance(): CalendarForecast {
    if (CalendarForecast.instanceValue === null) {
      CalendarForecast.instanceValue = new CalendarForecast();
    }
    return CalendarForecast.instanceValue;
  }

  /** 缓存签名：数据版本 + 站址 + 当天零点（窗口起点）任一变化即作废。 */
  static signatureOf(dataVersion: number): string {
    const st = AppSettings.getStation();
    const d = new Date();
    const today = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    return `${dataVersion}|${st.latitude}|${st.longitude}|${st.altitude}|${today}`;
  }

  /** 页面侧调用：签名变化时清空缓存。 */
  prepare(dataVersion: number): void {
    this.ensureSignature(CalendarForecast.signatureOf(dataVersion));
  }

  has(catnum: number): boolean {
    const c = this.cache.get(catnum);
    if (c === undefined) {
      return false;
    }
    // 命中即标记为最近使用（LRU），并做上限裁剪
    this.cache.delete(catnum);
    this.cache.set(catnum, c);
    return true;
  }

  /** 这批星是否全部已缓存（用于"缓存已热就立即汇总、不显示加载中"）。 */
  hasAll(cats: number[]): boolean {
    if (cats.length === 0) {
      return false;
    }
    for (let i = 0; i < cats.length; i++) {
      if (!this.cache.has(cats[i])) {
        return false;
      }
    }
    return true;
  }

  nameOf(catnum: number): string {
    const c = this.cache.get(catnum);
    return c === undefined ? '' : c.name;
  }

  passesOf(catnum: number): SatPassEvent[] {
    const c = this.cache.get(catnum);
    return c === undefined ? [] : c.passes;
  }

  /** 单颗星计算并入缓存（同步，调用方负责让帧）。 */
  computeOne(catnum: number, satData: SatOrbitalData, station: SatGeoPos, now: number): void {
    let passes: SatPassEvent[] = [];
    try {
      const obj: SatOrbitalObject = createOrbitalObject(satData);
      // 窗口起点对齐到「当天零点」：签名按天失效，若仍以预热时刻为起点，
      // 同一自然日内起点会随预热时刻漂移，缓存数据逐渐陈旧（含已过去的过境）。
      const d = new Date(now);
      const dayStart = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      passes = this.finder.getPasses(obj, station, dayStart, CAL_FORECAST_DAYS * 24);
    } catch (e) {
      passes = [];
    }
    this.cache.set(catnum, new CachedForecast(satData.name, passes));
    while (this.cache.size > MAX_CACHED_FORECASTS) {
      const oldest = this.cache.keys().next();
      if (oldest.done === true) {
        break;
      }
      this.cache.delete(oldest.value);
    }
  }

  /**
   * 后台预热：把已选星里尚未缓存的补算完。
   * 重复调用安全（已缓存跳过）；预热进行中再次请求会记下来，算完按最新参数补跑一轮。
   */
  async warmup(cats: number[], dataVersion: number): Promise<void> {
    const station = AppSettings.getStation();
    const req = new WarmRequest(cats.slice(), dataVersion, station, Date.now(),
      CalendarForecast.signatureOf(dataVersion));
    this.pendingReq = req;
    if (this.warming) {
      return;
    }
    this.warming = true;
    while (this.pendingReq !== null) {
      const cur = this.pendingReq;
      this.pendingReq = null;
      this.ensureSignature(cur.signature);
      // 首次预热先等启动首屏稳定，减少与启动动画/联网更新的抢线程
      await CalendarForecast.delayFirst();
      for (let i = 0; i < cur.cats.length; i++) {
        const catnum = cur.cats[i];
        if (this.cache.has(catnum)) {
          continue;
        }
        const satData = CalendarForecast.findSat(catnum);
        if (satData === null) {
          this.cache.set(catnum, new CachedForecast('', []));
          continue;
        }
        this.computeOne(catnum, satData, cur.station, cur.now);
        await CalendarForecast.yieldFrame();
      }
    }
    this.warming = false;
  }

  static findSat(catnum: number): SatOrbitalData | null {
    return SatelliteApp.getInstance().getStore().getByCatnum(catnum);
  }

  /** 首次预热前的等待：只在第一次调用时生效。 */
  private static delayFirst(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, CalendarForecast.firstWarmDone ? 0 : WARM_START_DELAY_MS);
      CalendarForecast.firstWarmDone = true;
    });
  }

  private ensureSignature(sig: string): void {
    if (sig !== this.signature) {
      this.cache.clear();
      this.signature = sig;
    }
  }

  private static yieldFrame(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, WARM_YIELD_MS);
    });
  }
}
