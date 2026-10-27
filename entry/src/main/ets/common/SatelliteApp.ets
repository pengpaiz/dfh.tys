/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Application-scoped singleton wiring data layer together.
 */

import { common } from '@kit.AbilityKit';
import { SatelliteStore } from '../data/storage/SatelliteStore';
import { SatelliteDownloader } from '../data/downloader/SatelliteDownloader';
import { SatelliteImporter } from '../data/importer/SatelliteImporter';
import { SatOrbitalData } from '../domain/predict/OrbitalData';
import { SatGeoPos } from '../domain/predict/GeoPos';
import { AppSettings } from './AppSettings';
import { bytesToString } from './utils/TextUtils';

const STATION_LAT = 'station_latitude';
const STATION_LON = 'station_longitude';
const STATION_ALT = 'station_altitude';

const RAWFILE_TLE_SNAPSHOT = 'tle_snapshot.txt';
const RAWFILE_TRANSPONDER_SNAPSHOT = 'transponder_snapshot.json';
/** 内置快照的元数据（抓取时间/来源/条数），随镜像数据一起打包 */
const RAWFILE_SNAPSHOT_INFO = 'snapshot_info.json';

/** snapshot_info.json 的原始结构（字段可能缺失，读取时逐个校验） */
interface SnapshotInfoRaw {
  source?: string;
  transponderSource?: string;
  fetchedAt?: number;
  tleCount?: number;
  transponderCount?: number;
  newestEpoch?: string;
}

/** AppStorage key：内置离线数据（打包快照）的版本时间与来源，供设置页显示 */
const K_BUILTIN_SNAPSHOT_TIME = 'builtin_snapshot_time';
const K_BUILTIN_SNAPSHOT_SOURCE = 'builtin_snapshot_source';
export const ISS_CATNUM = 25544;

export class SatelliteApp {
  private static instanceValue: SatelliteApp | null = null;
  private store: SatelliteStore = new SatelliteStore();
  private downloader: SatelliteDownloader = new SatelliteDownloader();
  private importer: SatelliteImporter = new SatelliteImporter();
  private startupDone: boolean = false;
  private storeLoaded: boolean = false;
  /** 内置快照元数据（启动时读取一次） */
  private snapshotFetchedAt: number = 0;
  private snapshotSource: string = '';
  private ctx: common.Context | null = null;

  static getInstance(): SatelliteApp {
    if (SatelliteApp.instanceValue === null) {
      SatelliteApp.instanceValue = new SatelliteApp();
    }
    return SatelliteApp.instanceValue;
  }

  init(context: common.Context): void {
    this.store.setContext(context);
    this.ctx = context;
  }

  getStore(): SatelliteStore {
    return this.store;
  }

  async loadFromDisk(): Promise<void> {
    await this.store.load();
    this.storeLoaded = true;
    // 本地数据就绪立刻通知页面重算：否则过境/日历要一直等到联网更新（已延后）才出数据
    if (this.store.getAll().length > 0) {
      this.bumpDataVersion();
    }
  }

  /** 本地数据是否已加载完成（用于区分"还没加载"与"确实没有数据"） */
  hasStoreLoaded(): boolean {
    return this.storeLoaded;
  }

  /**
   * 读取打包进包里的内置离线数据快照元数据（rawfile/snapshot_info.json），
   * 把"内置离线数据版本时间"发布到 AppStorage，供设置页标明（与是否联网无关）。
   */
  async loadSnapshotInfo(): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    try {
      const raw = await this.ctx.resourceManager.getRawFileContent(RAWFILE_SNAPSHOT_INFO);
      const info = JSON.parse(bytesToString(raw)) as SnapshotInfoRaw;
      this.snapshotFetchedAt = typeof info.fetchedAt === 'number' ? info.fetchedAt : 0;
      this.snapshotSource = typeof info.source === 'string' ? info.source : '';
      AppStorage.setOrCreate<number>(K_BUILTIN_SNAPSHOT_TIME, this.snapshotFetchedAt);
      AppStorage.setOrCreate<string>(K_BUILTIN_SNAPSHOT_SOURCE, this.snapshotSource);
    } catch (e) {
      // 没有元数据文件时忽略（老版本包）
    }
  }

  /**
   * 启动时的离线准备：若本机还没有数据，从内置快照导入，保证首屏即有数据。
   * 不联网、不定位——位置权限只在用户主动点「定位到当前位置」时才申请（最小必要 / 按需授权）。
   */
  async startupOfflineSeed(): Promise<void> {
    if (this.startupDone) {
      return;
    }
    this.startupDone = true;
    // 首次使用且无本地数据：立即从内置快照离线导入，保证第一次打开即可展示数据
    if (this.store.getAll().length === 0) {
      const seeded = await this.seedFromSnapshot();
      if (seeded > 0) {
        this.bumpDataVersion();
      }
    }
  }

  /**
   * 从内置快照重新导入（离线重载）：不联网，供设置页「重载内置数据」使用。
   * 返回重载后的卫星数（失败返回 0，保留原有数据）。
   */
  async reloadFromSnapshot(): Promise<number> {
    const seeded = await this.seedFromSnapshot();
    if (seeded > 0) {
      this.bumpDataVersion();
    }
    return seeded;
  }

  async downloadAndStore(): Promise<number> {
    let dataList: SatOrbitalData[] | null = null;
    let usedUrl: string = '';
    let customFailed: boolean = false;
    try {
      const result = await this.downloader.downloadWithFallback(AppSettings.getCustomTleUrl());
      dataList = result.dataList;
      usedUrl = result.sourceUrl;
      customFailed = result.customFailed;
    } catch (e) {
      // 所有在线源失败：记下自定义地址这次失败，无本地数据时回退内置快照，否则抛出提示
      this.recordCustomFailureIfConfigured();
      if (this.store.getAll().length === 0) {
        const seeded = await this.seedFromSnapshot();
        if (seeded > 0) {
          this.bumpDataVersion();
          return seeded;
        }
      }
      const msg = e instanceof Error ? e.message : 'download failed';
      throw new Error(msg);
    }
    this.store.replaceAll(dataList);
    this.store.dedupeKeepFreshest();
    await this.store.save();
    this.recordDataSource(usedUrl, customFailed);
    this.bumpDataVersion();
    return this.store.getAll().length;
  }

  /**
   * 记录这次卫星数据实际用的是哪个渠道（内置离线数据 / 用户自定义），
   * 供设置页显示"当前模式 + 各自最近更新时间 / 自定义地址成功或失败"。
   */
  private recordDataSource(usedUrl: string, customFailed: boolean): void {
    if (usedUrl.length === 0) {
      return;
    }
    const custom = AppSettings.getCustomTleUrl();
    const isCustom = custom.length > 0 && usedUrl === custom;
    AppSettings.recordDataSourceResult(usedUrl, !isCustom, isCustom);
    if (isCustom) {
      AppSettings.recordCustomResult(true);
    } else if (customFailed) {
      AppSettings.recordCustomResult(false);
    }
  }

  /** 全部源都失败时：若用户填了自定义地址，记为一次失败。 */
  private recordCustomFailureIfConfigured(): void {
    if (AppSettings.getCustomTleUrl().length > 0) {
      AppSettings.recordCustomResult(false);
    }
  }

  /** 从 rawfile 内置快照离线导入，返回导入的卫星数（失败返回 0）。 */
  private async seedFromSnapshot(): Promise<number> {
    if (this.ctx === null) {
      return 0;
    }
    try {
      const raw = await this.ctx.resourceManager.getRawFileContent(RAWFILE_TLE_SNAPSHOT);
      const text = bytesToString(raw);
      const result = this.downloader.parseTLEText(text);
      if (result.count === 0) {
        return 0;
      }
      this.store.replaceAll(result.dataList);
      this.store.dedupeKeepFreshest();
      await this.store.save();
      try {
        const rawT = await this.ctx.resourceManager.getRawFileContent(RAWFILE_TRANSPONDER_SNAPSHOT);
        const textT = bytesToString(rawT);
        const t = this.downloader.parseTransponderText(textT);
        this.store.setTransponders(t.transponders);
        await this.store.saveTransponders();
      } catch (e) {
        // 转发器快照可选
      }
      // 记录内置快照自带的抓取时间（= 打包时从镜像下载的时刻），
      // 这样"内置离线数据版本时间"显示的是快照数据的获取时间，而不是本次导入时间。
      await this.recordSnapshotInfo();
      return this.store.getAll().length;
    } catch (e) {
      return 0;
    }
  }

  /** 读取 rawfile/snapshot_info.json，把内置离线数据的版本时间记为快照抓取时间。 */
  private async recordSnapshotInfo(): Promise<void> {
    if (this.snapshotFetchedAt <= 0) {
      await this.loadSnapshotInfo();
    }
    if (this.snapshotFetchedAt > 0) {
      AppSettings.recordDataSourceResult(this.snapshotSource, true, false, this.snapshotFetchedAt);
    }
  }

  private bumpDataVersion(): void {
    const v = AppStorage.get<number>('data_version') ?? 0;
    AppStorage.setOrCreate<number>('data_version', v + 1);
  }

  /** 下载转发器数据（国内加速镜像）到 store，返回条数。 */
  async downloadTranspondersAndStore(): Promise<number> {
    const result = await this.downloader.downloadTransponders(AppSettings.getCustomTransponderUrl());
    this.store.setTransponders(result.transponders);
    await this.store.saveTransponders();
    return result.count;
  }

  async importAndStore(context: common.Context): Promise<number> {
    const result = await this.importer.pickAndParse(context);
    if (result === null) {
      return -1;
    }
    this.store.replaceAll(result.dataList);
    this.store.dedupeKeepFreshest();
    await this.store.save();
    this.bumpDataVersion();
    return this.store.getAll().length;
  }

  getDownloader(): SatelliteDownloader {
    return this.downloader;
  }

  getImporter(): SatelliteImporter {
    return this.importer;
  }

  getStation(): SatGeoPos {
    const lat = AppStorage.get<number>(STATION_LAT);
    const lon = AppStorage.get<number>(STATION_LON);
    const alt = AppStorage.get<number>(STATION_ALT);
    return new SatGeoPos(
      lat === undefined ? 48.2 : lat,
      lon === undefined ? 16.37 : lon,
      alt === undefined ? 0 : alt,
      'station'
    );
  }

  getCatalogPreview(list: SatOrbitalData[]): string {
    if (list.length === 0) {
      return '无卫星数据';
    }
    return `共 ${list.length} 颗卫星`;
  }
}