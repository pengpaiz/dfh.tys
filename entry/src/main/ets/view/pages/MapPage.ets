/*
 * Look4Sat. World map page (PRC-standard global outline, offline canvas).
 * Night-theme fixed-view map: no pan/zoom. Shows only:
 *  - selected satellite future ground track (one line, until it exits the map)
 *  - footprint (coverage) range circle
 *  - observer station + live satellite positions
 * True-scale local projection: longitude span widens by 1/cos(center latitude),
 * so shapes (footprint, track, landmass) are not distorted at high latitudes.
 */

import { WORLD_RINGS } from '../../domain/map/WorldOutline';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ENTER_SCALE, PRESS_IN_MS, PRESS_OUT_MS, PRESS_SCALE } from '../components/PressFx';
import { KEY_BAR_CLEARANCE, TAB_BAR_CLEARANCE } from '../../common/LayoutMetrics';
import { SatelliteApp } from '../../common/SatelliteApp';
import { SelectedSats } from '../../common/SelectedSats';
import { AppSettings } from '../../common/AppSettings';
import { SAT_COLORS } from '../../common/SatColors';
import { SatOrbitalData } from '../../domain/predict/OrbitalData';
import { createOrbitalObject } from '../../domain/predict/OrbitalFactory';
import { SatPassEvent, SatPassFinder } from '../../domain/predict/SatPassFinder';
import { SatOrbitalObject } from '../../domain/predict/OrbitalObject';
import { SatOrbitalPos } from '../../domain/predict/OrbitalPos';
import { SatGeoPos } from '../../domain/predict/GeoPos';
import { positionToQth } from '../../domain/qth/QthConverter';
import { toDegrees } from '../../common/utils/MathUtils';
import { RAD2DEG, DEG2RAD, EARTH_RADIUS } from '../../domain/predict/Constants';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAB_MAP = 1;
const MAP_REFRESH_MS = 1000;
const TRACK_SAMPLE_STEP_MS = 60000;
const TRACK_PERIODS = 2.0;
const MAX_WINDOW_H = 48;
// Viewport window, center follows satellite. Stack aspect ratio is 1.25, so
// BASE_LON_SPAN = VIEW_LAT_SPAN * 1.25 keeps 1° lon == 1° lat in pixels at the equator.
// At high latitudes the effective lon span widens by 1/cos(lat) so shapes keep true scale.
const VIEW_LAT_SPAN = 52.0;
const BASE_LON_SPAN = 65.0;
const MAX_CENTER_LAT = 90.0 - VIEW_LAT_SPAN / 2;
const DEFAULT_CENTER_LON = 105.0;
const DEFAULT_CENTER_LAT = 35.0;
const WATER_COLOR = '#0D1B2A';
const LAND_COLOR = '#16283C';
const BORDER_COLOR = '#33507A';
const GRID_COLOR = '#1F3550';
const STATION_COLOR = '#E53935';
const TRACK_COLOR = '#FF4D4D';
const LIVE_COLOR = '#F5C518';
const FOOTPRINT_COLOR = '#538EF4';

class MapSatInfo {
  catnum: number = 0;
  name: string = '';
  color: string = '';
  obj: SatOrbitalObject;
  pass: SatPassEvent | null = null;
  lats: number[] = [];
  lons: number[] = [];
  times: number[] = [];

  constructor(catnum: number, name: string, color: string, obj: SatOrbitalObject) {
    this.catnum = catnum;
    this.name = name;
    this.color = color;
    this.obj = obj;
  }
}

@Component
export struct MapPage {
  @State sats: MapSatInfo[] = [];
  @State selectedIndex: number = 0;
  @State nowTs: number = Date.now();
  /**
   * 信息胶囊文本（15 项）。
   * 必须做成 @State：ArkUI 的 @Builder **按值传参不会随参数变化刷新**，
   * 之前 `chip(this.azimuthText())` 因此每秒不更新（地图是命令式重绘所以看起来在动）。
   */
  @State chipValues: string[] = ['方位 --', '仰角 --', '高度 --', '距离 --', '速率 --', '速度 --',
    '星下 --', 'QTH --', '下次 --', '周期 --', '倾角 --', '偏心率 --', '平近点角 --', 'NORAD --', '站址 --'];
  @State viewCenterLon: number = DEFAULT_CENTER_LON;
  @State viewCenterLat: number = DEFAULT_CENTER_LAT;
  @StorageLink('selected_version') @Watch('recompute') selVersion: number = 0;
  @StorageLink('data_version') @Watch('recompute') dataVersion: number = 0;
  @StorageLink('station_latitude') @Watch('recompute') stationLat: number = 48.2;
  @StorageLink('station_longitude') @Watch('recompute') stationLon: number = 16.37;
  @StorageLink('station_altitude') @Watch('recompute') stationAlt: number = 0;
  @StorageProp('current_tab') @Watch('onTabChanged') currentTab: number = TAB_MAP;
  /** 当前激活的子页签（0=地图 / 1=日历）：地图并入「追踪」后靠它判断自身是否真的可见 */
  @StorageProp('tracking_sub') @Watch('onTrackSubChanged') trackSub: number = 0;

  private dirty: boolean = false;
  @State pressedBtn: string = '';
  @State btnEntered: boolean = false;
  /** 底部预留（由 Index 按栏高+导航条避让算出后发布） */
  @StorageProp(KEY_BAR_CLEARANCE) barClearance: number = TAB_BAR_CLEARANCE;
  /** 切换卫星时中间文字信息的切换动画：进度 0→1，方向 -1 上一颗 / +1 下一颗 */
  @State infoFx: number = 1;
  @State infoDir: number = 1;
  /** 暗色主题：地图配色随之切换（白天/夜间两套） */
  @State isDark: boolean = false;
  private app: SatelliteApp = SatelliteApp.getInstance();
  private finder: SatPassFinder = new SatPassFinder();
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private lastW: number = 0;
  private lastH: number = 0;
  private timerId: number = -1;
  private lastPassRefresh: number = 0;
  /** 同一 (nowTs, catnum) 内复用当前位置：避免每个信息 chip 与地图绘制各传播一次轨道 */
  private posCache: SatOrbitalPos | null = null;
  private posCacheKeyTime: number = Number.NaN;
  /** 地图配色：按亮/暗主题切换（白天=浅底深线，夜间=现有深色）。
   *  方法统一加 map 前缀，避免与 ArkUI 内建属性（borderColor 等）撞名。 */
  private mapWaterColor(): string {
    return this.isDark ? WATER_COLOR : '#DCEBF7';
  }
  private mapLandColor(): string {
    return this.isDark ? LAND_COLOR : '#F2F6FA';
  }
  private mapBorderColor(): string {
    return this.isDark ? BORDER_COLOR : '#C7D6E6';
  }
  private mapGridColor(): string {
    return this.isDark ? GRID_COLOR : '#E3EBF3';
  }
  private mapLiveColor(): string {
    return this.isDark ? LIVE_COLOR : '#D9A400';
  }
  /** 标记描边：夜间用白边，白天用深边（保证在浅底上可见） */
  private markerEdge(): string {
    return this.isDark ? '#FFFFFF' : '#1B1C1E';
  }

  private posCacheKeyCat: number = -1;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.dirty = false;
    this.doRecompute();
    this.timerId = setInterval((): void => {
      this.nowTs = Date.now();
      // 本页不可见（切到日历子页签或其它底部标签）时不做轨道传播与重绘：
      // Tabs 切页不会销毁本页，定时器仍在每秒空转。
      if (!this.isVisible()) {
        return;
      }
      this.refreshSelectedPass(false);
      this.refreshSelectedTrack();
      this.followSelectedSat();
      this.drawNow();
      }, MAP_REFRESH_MS);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 本页不可见时只记脏标记：选星/换站点不再同步触发这里 48h 过境+轨迹重算。 */
  recompute(): void {
    if (this.currentTab !== TAB_MAP) {
      this.dirty = true;
      return;
    }
    this.dirty = false;
    this.doRecompute();
  }

  /** 本页是否真的可见：既要在「追踪」标签上，子页签也必须是「地图」。 */
  private isVisible(): boolean {
    return this.currentTab === TAB_MAP && this.trackSub === 0;
  }

  onTabChanged(): void {
    if (this.isVisible() && this.dirty) {
      this.dirty = false;
      this.doRecompute();
    }
  }

  /** 在「追踪」内切回地图子页签：有待算内容就立即重算。 */
  onTrackSubChanged(): void {
    if (this.isVisible() && this.dirty) {
      this.dirty = false;
      this.doRecompute();
    }
  }

  private doRecompute(): void {
    const prevCat = this.selectedCatnum();
    const cats = SelectedSats.getCats();
    const store = this.app.getStore();
    const station = AppSettings.getStation();
    const all = store.getAll();
    const now = Date.now();
    const list: MapSatInfo[] = [];
    for (let i = 0; i < cats.length; i++) {
      const satData = this.findSat(all, cats[i]);
      if (satData === null) {
        continue;
      }
      let obj: SatOrbitalObject;
      try {
        obj = createOrbitalObject(satData);
      } catch (e) {
        hilog.warn(0x0001, 'MapPage', `skip bad TLE ${cats[i]}`);
        continue;
      }
      const info = new MapSatInfo(cats[i], satData.name, SAT_COLORS[i % SAT_COLORS.length], obj);
      try {
        const passes = this.finder.getPasses(obj, station, now, MAX_WINDOW_H);
        info.pass = this.nextPass(passes, now);
      } catch (e) {
        hilog.warn(0x0001, 'MapPage', `pass fail ${satData.name}`);
      }
      if (obj.data.meanmo > 1e-8) {
        this.sampleTrack(info, now, station);
      }
      list.push(info);
    }
    this.sats = list;
    // 保持当前选中的卫星（按 NORAD 编号），而不是按列表下标
    this.selectedIndex = this.indexOfCat(prevCat);
    this.lastPassRefresh = Date.now();
    this.followSelectedSat();
    this.drawNow();
  }

  /** Ground track samples: TRACK_PERIODS orbital periods ahead of [now]. */
  private sampleTrack(info: MapSatInfo, now: number, station: SatGeoPos): void {
    const lats: number[] = [];
    const lons: number[] = [];
    const times: number[] = [];
    const end = now + TRACK_PERIODS * info.obj.data.orbitalPeriod * 60000;
    let t = now;
    let guard = 0;
    while (t <= end && guard < 4000) {
      try {
        const pos = info.obj.getPosition(station, t);
        lats.push(pos.latitude * RAD2DEG);
        lons.push(this.wrapLon(pos.longitude * RAD2DEG));
        times.push(t);
      } catch (e) {
        // propagation failed for this sample: keep the partial track
      }
      t += TRACK_SAMPLE_STEP_MS;
      guard++;
    }
    info.lats = lats;
    info.lons = lons;
    info.times = times;
  }

  /**
   * 轨道采样固定在 recompute 时刻，随时间推移未来采样点会被耗尽（2 个轨道周期后
   * 轨迹消失）。这里在剩余未来采样不足 10 分钟时重新采样当前卫星的轨迹。
   */
  private refreshSelectedTrack(): void {
    const info = this.selectedSat();
    if (info === null || info.times.length === 0) {
      return;
    }
    const last = info.times[info.times.length - 1];
    if (this.nowTs < last - 600000) {
      return;
    }
    this.sampleTrack(info, this.nowTs, AppSettings.getStation());
  }

  private selectedCatnum(): number {
    const info = this.selectedSat();
    return info === null ? -1 : info.catnum;
  }

  private indexOfCat(catnum: number): number {
    if (catnum < 0) {
      return 0;
    }
    for (let i = 0; i < this.sats.length; i++) {
      if (this.sats[i].catnum === catnum) {
        return i;
      }
    }
    return 0;
  }

  /** 当前选中卫星的过境预报到期后自动重算，保证倒计时/下次过境始终有效。 */
  private refreshSelectedPass(force: boolean): void {
    const info = this.selectedSat();
    if (info === null) {
      return;
    }
    const now = this.nowTs;
    const expired = info.pass === null || info.pass.losTime < now;
    if (!force && !expired && now - this.lastPassRefresh < 60000) {
      return;
    }
    this.lastPassRefresh = now;
    const station = AppSettings.getStation();
    try {
      const passes = this.finder.getPasses(info.obj, station, now, MAX_WINDOW_H);
      info.pass = this.nextPass(passes, now);
    } catch (e) {
      // 保留旧预报
    }
  }

  private nextPass(passes: SatPassEvent[], now: number): SatPassEvent | null {
    for (let i = 0; i < passes.length; i++) {
      if (passes[i].losTime > now && passes[i].aosTime > now - 60000) {
        return passes[i];
      }
    }
    return null;
  }

  /** Center the viewport on the selected satellite's current ground position. */
  private followSelectedSat(): void {
    const pos = this.currentPosition();
    if (pos === null) {
      return;
    }
    this.viewCenterLon = this.wrapLon(toDegrees(pos.longitude));
    // keep the pole at/inside the map edge: never show latitude beyond ±90
    this.viewCenterLat = Math.max(-MAX_CENTER_LAT, Math.min(MAX_CENTER_LAT, toDegrees(pos.latitude)));
  }

  /** Wrap longitude to [-180, 180). */
  private wrapLon(lon: number): number {
    let v = lon;
    while (v >= 180.0) {
      v -= 360.0;
    }
    while (v < -180.0) {
      v += 360.0;
    }
    return v;
  }

  private fmtLat(lat: number): string {
    return `${Math.abs(lat).toFixed(1)}°${lat >= 0 ? 'N' : 'S'}`;
  }

  private fmtLon(lon: number): string {
    return `${Math.abs(lon).toFixed(1)}°${lon >= 0 ? 'E' : 'W'}`;
  }

  private selectedSat(): MapSatInfo | null {
    if (this.sats.length === 0 || this.selectedIndex < 0 || this.selectedIndex >= this.sats.length) {
      return null;
    }
    return this.sats[this.selectedIndex];
  }

  private selectPrev(): void {
    if (this.sats.length === 0) {
      return;
    }
    this.selectedIndex = (this.selectedIndex + this.sats.length - 1) % this.sats.length;
    this.refreshSelectedPass(true);
    this.followSelectedSat();
    this.drawNow();
    this.infoDir = -1;
    this.playInfoFx();
  }

  private selectNext(): void {
    if (this.sats.length === 0) {
      return;
    }
    this.selectedIndex = (this.selectedIndex + 1) % this.sats.length;
    this.refreshSelectedPass(true);
    this.followSelectedSat();
    this.drawNow();
    this.infoDir = 1;
    this.playInfoFx();
  }

  private findSat(all: SatOrbitalData[], catnum: number): SatOrbitalData | null {
    for (let i = 0; i < all.length; i++) {
      if (all[i].catnum === catnum) {
        return all[i];
      }
    }
    return null;
  }

  // ---- countdown ----

  private currentPosition(): SatOrbitalPos | null {
    const info = this.selectedSat();
    if (info === null) {
      this.posCache = null;
      return null;
    }
    // 同一帧内多个信息 chip 与地图绘制都要用位置，按 (nowTs, catnum) 复用，只传播一次。
    if (this.posCache !== null && this.posCacheKeyTime === this.nowTs && this.posCacheKeyCat === info.catnum) {
      return this.posCache;
    }
    const station = AppSettings.getStation();
    try {
      const pos = info.obj.getFullPosition(station, this.nowTs);
      this.posCache = pos;
      this.posCacheKeyTime = this.nowTs;
      this.posCacheKeyCat = info.catnum;
      return pos;
    } catch (e) {
      hilog.warn(0x0001, 'MapPage', `pos fail ${info.name}`);
      this.posCache = null;
      return null;
    }
  }

  private countdownLabel(): string {
    const info = this.selectedSat();
    if (info === null || info.pass === null) {
      return '--:--:--';
    }
    const p = info.pass;
    if (this.nowTs < p.aosTime) {
      return this.fmtCountdown(p.aosTime - this.nowTs);
    }
    if (this.nowTs < p.losTime) {
      return this.fmtCountdown(p.losTime - this.nowTs);
    }
    return '--:--:--';
  }

  private countdownHint(): string {
    const info = this.selectedSat();
    if (info === null || info.pass === null) {
      return '待过境';
    }
    const p = info.pass;
    if (this.nowTs < p.aosTime) {
      return '距 AOS';
    }
    if (this.nowTs < p.losTime) {
      return '距 LOS';
    }
    return '待过境';
  }

  private fmtCountdown(ms: number): string {
    const s = Math.max(0, Math.floor(ms / 1000));
    const hh = Math.floor(s / 3600).toString().padStart(2, '0');
    const mm = Math.floor((s % 3600) / 60).toString().padStart(2, '0');
    const ss = (s % 60).toString().padStart(2, '0');
    return `${hh}:${mm}:${ss}`;
  }

  // ---- drawing ----

  private drawNow(): void {
    // 每帧刷新信息胶囊文本（@Builder 按值传参不刷新，故文本统一走 @State 数组）
    this.refreshChipValues();
    if (this.lastW > 0 && this.lastH > 0) {
      this.drawCanvas(this.lastW, this.lastH);
    }
  }

  private drawCanvas(width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    // 每秒重绘时同步主题：白天/夜间切换后地图配色自动跟随
    const ctx = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    try {
      this.renderCanvas(width, height);
    } catch (e) {
      hilog.error(0x0001, 'MapPage', `draw fail: ${JSON.stringify(e)}`);
    }
  }

  private renderCanvas(width: number, height: number): void {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = this.mapWaterColor();
    ctx.fillRect(0, 0, width, height);
    this.drawGrid(ctx, width, height);

    ctx.fillStyle = this.mapLandColor();
    ctx.strokeStyle = this.mapBorderColor();
    ctx.lineWidth = 1;
    for (let i = 0; i < WORLD_RINGS.length; i++) {
      this.traceRing(ctx, WORLD_RINGS[i], width, height);
      ctx.fill();
      ctx.stroke();
    }

    const station = AppSettings.getStation();

    const info = this.selectedSat();
    if (info !== null) {
      this.drawTrack(ctx, info, width, height);

      const pos = this.currentPosition();
      if (pos !== null && pos.altitude > 0) {
        this.drawFootprint(ctx, pos, width, height);
      }
    }

    // live positions of all selected satellites.
    // Each satellite is isolated: a propagator error on one of them must not
    // abort the whole render (which left the footprint drawn without markers).
    for (let i = 0; i < this.sats.length; i++) {
      const sat = this.sats[i];
      let p: SatOrbitalPos;
      try {
        p = sat.obj.getFullPosition(station, this.nowTs);
      } catch (e) {
        hilog.warn(0x0001, 'MapPage', `marker fail ${sat.name}`);
        continue;
      }
      if (p.altitude <= 0) {
        continue;
      }
      const lon = this.wrapLon(toDegrees(p.longitude));
      const lat = toDegrees(p.latitude);
      if (!this.lonInView(lon) || !this.latInView(lat)) {
        continue;
      }
      const x = this.px(lon, width);
      const y = this.py(lat, height);
      const selected = i === this.selectedIndex;
      ctx.save();
      ctx.fillStyle = selected ? this.mapLiveColor() : sat.color;
      ctx.strokeStyle = this.markerEdge();
      ctx.lineWidth = selected ? 2 : 1;
      ctx.beginPath();
      ctx.arc(x, y, selected ? 6 : 4, 0, Math.PI * 2);
      ctx.fill();
      if (selected) {
        ctx.stroke();
      }
      ctx.restore();
    }

    // station marker
    const sx = this.px(station.longitude, width);
    const sy = this.py(station.latitude, height);
    ctx.save();
    ctx.fillStyle = STATION_COLOR;
    ctx.strokeStyle = this.markerEdge();
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(sx, sy, 5, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  /**
   * Coverage circle of the satellite. Under this map's local true-scale projection
   * (longitude stretched by 1/cos(centerLat), latitude linear) a spherical cap of
   * angular radius beta centred on the sub-satellite point maps to a true circle, so
   * it is drawn in pixel space. This avoids the pole/antimeridian self-intersection
   * that made the outline malformed at high latitudes.
   */
  private drawFootprint(ctx: CanvasRenderingContext2D, pos: SatOrbitalPos, width: number, height: number): void {
    const betaRad = Math.acos(EARTH_RADIUS / (EARTH_RADIUS + pos.altitude));
    const radiusPx = betaRad * RAD2DEG * (height / VIEW_LAT_SPAN);
    if (!Number.isFinite(radiusPx) || radiusPx <= 0) {
      return;
    }
    const x = this.px(this.wrapLon(toDegrees(pos.longitude)), width);
    const y = this.py(toDegrees(pos.latitude), height);
    ctx.save();
    ctx.strokeStyle = FOOTPRINT_COLOR;
    ctx.fillStyle = FOOTPRINT_COLOR;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(x, y, radiusPx, 0, Math.PI * 2);
    ctx.globalAlpha = 0.18;
    ctx.fill();
    ctx.globalAlpha = 0.75;
    ctx.stroke();
    ctx.restore();
  }

  /**
   * Draw the future ground track of the selected satellite: only one continuous
   * line starting at the live position and running until it leaves the map.
   * Already-passed samples (behind the satellite) are not drawn. Longitudes are
   * unwrapped continuously so the line never breaks at the antimeridian or near
   * the poles where longitude changes fast.
   */
  private drawTrack(ctx: CanvasRenderingContext2D, info: MapSatInfo, width: number, height: number): void {
    const lons = info.lons;
    const lats = info.lats;
    const times = info.times;
    if (lons.length === 0) {
      return;
    }
    const half = this.lonSpan() / 2;
    const start = this.currentPosition();
    ctx.save();
    ctx.strokeStyle = TRACK_COLOR;
    ctx.lineWidth = 2.5;
    ctx.globalAlpha = 0.95;
    ctx.beginPath();
    let started = false;
    let prev = 0;
    for (let j = 0; j < lons.length; j++) {
      if (times[j] < this.nowTs) {
        continue; // already-passed portion of the orbit
      }
      let lon = lons[j];
      if (!started) {
        lon = this.relLon(lon);
      } else {
        while (lon - prev > 180.0) {
          lon -= 360.0;
        }
        while (lon - prev < -180.0) {
          lon += 360.0;
        }
      }
      const lat = lats[j];
      const inView = Math.abs(lon - this.viewCenterLon) <= half && this.latInView(lat);
      const x = this.pxRaw(lon, width);
      const y = this.py(lat, height);
      if (!started) {
        if (!inView) {
          prev = lon;
          continue;
        }
        if (start !== null) {
          // seamless: start the line at the live satellite position
          ctx.moveTo(this.pxRaw(this.relLon(this.wrapLon(toDegrees(start.longitude))), width),
            this.py(toDegrees(start.latitude), height));
          ctx.lineTo(x, y);
        } else {
          ctx.moveTo(x, y);
        }
        started = true;
        prev = lon;
        continue;
      }
      // extend the line through the map edge, then stop: later passes are not drawn
      ctx.lineTo(x, y);
      if (!inView) {
        break;
      }
      prev = lon;
    }
    if (started) {
      ctx.stroke();
    }
    ctx.restore();
  }

  private drawGrid(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    ctx.save();
    ctx.strokeStyle = this.mapGridColor();
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.6;
    for (let lon = -180; lon <= 180; lon += 30) {
      const x = this.px(lon, width);
      if (x < 0 || x > width) {
        continue;
      }
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
      ctx.stroke();
    }
    for (let lat = -90; lat <= 90; lat += 30) {
      const y = this.py(lat, height);
      if (y < 0 || y > height) {
        continue;
      }
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
      ctx.stroke();
    }
    // latitude / longitude labels
    ctx.globalAlpha = 0.9;
    ctx.fillStyle = '#6E8BB5';
    ctx.font = '10px sans-serif';
    for (let lon = -180; lon <= 180; lon += 30) {
      const x = this.px(lon, width);
      if (x >= 24 && x <= width - 24) {
        ctx.fillText(this.fmtLon(lon), x - 16, 12);
      }
    }
    for (let lat = -90; lat <= 90; lat += 30) {
      const y = this.py(lat, height);
      if (y >= 22 && y <= height - 8) {
        ctx.fillText(this.fmtLat(lat), 4, y - 4);
      }
    }
    ctx.restore();
  }

  private traceRing(ctx: CanvasRenderingContext2D, ring: number[][], width: number, height: number): void {
    if (ring.length < 3) {
      return;
    }
    // Unwrap longitudes continuously and anchor the ring near the view center so
    // landmasses render correctly even when the viewport crosses the antimeridian.
    let prev = ring[0][0];
    const shift = Math.round((this.viewCenterLon - prev) / 360.0) * 360.0;
    ctx.beginPath();
    for (let i = 0; i < ring.length; i++) {
      let lon = ring[i][0];
      while (lon - prev > 180.0) {
        lon -= 360.0;
      }
      while (lon - prev < -180.0) {
        lon += 360.0;
      }
      prev = lon;
      const x = this.pxRaw(lon + shift, width);
      const y = this.py(ring[i][1], height);
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.closePath();
  }

  /** Effective longitude span: widens by 1/cos(centerLat) so shapes keep true scale
   *  at high latitudes (a degree of longitude shrinks as you approach the pole). */
  private lonSpan(): number {
    const lat = Math.min(Math.abs(this.viewCenterLat), MAX_CENTER_LAT) * DEG2RAD;
    return BASE_LON_SPAN / Math.max(Math.cos(lat), 0.2);
  }

  /** Normalize [lon] into (viewCenterLon - 180, viewCenterLon + 180]. */
  private relLon(lon: number): number {
    let d = lon - this.viewCenterLon;
    while (d >= 180.0) {
      d -= 360.0;
    }
    while (d < -180.0) {
      d += 360.0;
    }
    return this.viewCenterLon + d;
  }

  private px(lon: number, width: number): number {
    return this.pxRaw(this.relLon(lon), width);
  }

  /** Map an already-unwrapped longitude linearly onto the canvas. */
  private pxRaw(lon: number, width: number): number {
    return (lon - (this.viewCenterLon - this.lonSpan() / 2)) / this.lonSpan() * width;
  }

  private py(lat: number, height: number): number {
    return ((this.viewCenterLat + VIEW_LAT_SPAN / 2) - lat) / VIEW_LAT_SPAN * height;
  }

  private lonInView(lon: number): boolean {
    return Math.abs(this.relLon(lon) - this.viewCenterLon) <= this.lonSpan() / 2;
  }

  private latInView(lat: number): boolean {
    return Math.abs(lat - this.viewCenterLat) <= VIEW_LAT_SPAN / 2;
  }

  // ---- info helpers ----

  private posText(): string {
    const pos = this.currentPosition();
    if (pos === null) {
      return '--';
    }
    return `${this.fmtLat(toDegrees(pos.latitude))} ${this.fmtLon(this.wrapLon(toDegrees(pos.longitude)))}`;
  }

  private qthText(): string {
    const pos = this.currentPosition();
    if (pos === null) {
      return '--';
    }
    return positionToQth(toDegrees(pos.latitude), this.wrapLon(toDegrees(pos.longitude))) ?? '--';
  }

  private stationText(): string {
    return `站 ${this.stationLat.toFixed(2)}, ${this.stationLon.toFixed(2)}`;
  }

  private rateText(): string {
    const pos = this.currentPosition();
    return pos === null ? '距变 --' : `距变 ${pos.distanceRate.toFixed(2)}km/s`;
  }

  private velocityText(): string {
    const pos = this.currentPosition();
    return pos === null ? '速度 --' : `速度 ${pos.getOrbitalVelocity().toFixed(2)}km/s`;
  }

  private periodText(): string {
    const info = this.selectedSat();
    return info === null ? '周期 --' : `周期 ${info.obj.data.orbitalPeriod.toFixed(1)}分`;
  }

  private inclText(): string {
    const info = this.selectedSat();
    return info === null ? '倾角 --' : `倾角 ${info.obj.data.incl.toFixed(1)}°`;
  }

  private eccnText(): string {
    const info = this.selectedSat();
    return info === null ? '偏心 --' : `偏心 ${info.obj.data.eccn.toFixed(5)}`;
  }

  private meanmoText(): string {
    const info = this.selectedSat();
    return info === null ? '均动 --' : `均动 ${info.obj.data.meanmo.toFixed(2)}圈/天`;
  }

  private noradText(): string {
    const info = this.selectedSat();
    return info === null ? 'NORAD --' : `NORAD ${info.catnum}`;
  }

  private phaseText(): string {
    const pos = this.currentPosition();
    if (pos === null) {
      return '--';
    }
    return `${toDegrees(pos.phase).toFixed(0)}°`;
  }

  private clock(millis: number): string {
    const d = new Date(millis);
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }

  // ---- 按钮动画 ----

  /**
   * 卫星信息切换动画：与卫星页选择动画同一套（320ms + Friction）。
   * 先把进度瞬回 0（duration=0 不产生动画），下一帧再动画到 1，
   * 避免同一帧"归零 + 动画到 1"被吞掉。
   */
  private playInfoFx(): void {
    this.getUIContext().animateTo({ duration: 0, curve: Curve.Linear }, (): void => {
      this.infoFx = 0;
    });
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
        this.infoFx = 1;
      });
    }, 0);
  }

  /** 入场：整组按钮从 0.86 回弹到 1；按压：当前按钮收到 0.9 再回弹。 */
  private pressScale(key: string): number {
    const base = this.btnEntered ? 1 : ENTER_SCALE;
    return this.pressedBtn === key ? base * PRESS_SCALE : base;
  }

  private onBtnTouch(key: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.getUIContext().animateTo({ duration: PRESS_IN_MS, curve: Curve.EaseOut }, (): void => {
        this.pressedBtn = key;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.getUIContext().animateTo({ duration: PRESS_OUT_MS, curve: Curve.EaseOut }, (): void => {
        if (this.pressedBtn === key) {
          this.pressedBtn = '';
        }
      });
    }
  }

  // ---- ui ----

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Button('‹')
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .fontSize(18)
          .fontColor($r('app.color.cc_on_primary'))
          .backgroundColor($r('app.color.cc_primary'))
          .enabled(this.sats.length > 0)
          .scale({ x: this.pressScale('map-prev'), y: this.pressScale('map-prev') })
          .onTouch((event: TouchEvent): void => {
            this.onBtnTouch('map-prev', event);
          })
          .onClick((): void => {
            this.selectPrev()
          })
        Column({ space: 2 }) {
          Text(this.maybeName())
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.cc_text_title'))
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 4 }) {
            Text(this.countdownHint())
              .fontSize(12)
              .fontColor($r('app.color.cc_text_muted'))
            Text(this.countdownLabel())
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.cc_accent_text'))
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        // 切换卫星：文字按方向滑入 + 淡入（320ms Friction）
        .opacity(0.15 + 0.85 * this.infoFx)
        .translate({ x: 12 * this.infoDir * (1 - this.infoFx) })

        Button('›')
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .fontSize(18)
          .fontColor($r('app.color.cc_on_primary'))
          .backgroundColor($r('app.color.cc_primary'))
          .enabled(this.sats.length > 0)
          .scale({ x: this.pressScale('map-next'), y: this.pressScale('map-next') })
          .onTouch((event: TouchEvent): void => {
            this.onBtnTouch('map-next', event);
          })
          .onClick((): void => {
            this.selectNext()
          })
      }
      .width('100%')
      // 收窄左右留白，给过长的卫星名留出更多宽度
      .padding({ left: 8, right: 8, top: 8, bottom: 0 })
      .onAppear((): void => {
        this.getUIContext().animateTo({ duration: PRESS_OUT_MS, curve: Curve.EaseOut }, (): void => {
          this.btnEntered = true;
        });
      })

      // China-viewport night map, moderate size (not stretched full screen)
      Stack() {
        Canvas(this.ctx)
          .width('100%')
          .height('100%')
          .onReady(() => {
            const w = Number(this.ctx.width);
            const h = Number(this.ctx.height);
            if (w > 0 && h > 0) {
              this.lastW = w;
              this.lastH = h;
              this.drawCanvas(w, h);
            }
          })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const w = Number(newValue.width);
            const h = Number(newValue.height);
            if (w > 0 && h > 0) {
              this.lastW = w;
              this.lastH = h;
              this.drawCanvas(w, h);
            }
          })
      }
      .width('100%')
      // 回退：地图恢复原比例
      .aspectRatio(1.25)
      .clip(true)

      // 详情面板：3 列等宽胶囊网格（不滚动，一屏显示完整）
      Column() {
        Column({ space: 8 }) {
            // —— 数据网格：3 列等宽，短项 2+1，长项通栏 ——
Grid() {
              GridItem() {
                this.chip(0)
              }.columnStart(0).columnEnd(0)
              GridItem() {
                this.chip(1)
              }.columnStart(1).columnEnd(1)
              GridItem() {
                this.chip(2)
              }.columnStart(2).columnEnd(2)

              GridItem() {
                this.chip(3)
              }.columnStart(0).columnEnd(0)
              GridItem() {
                this.chip(4)
              }.columnStart(1).columnEnd(1)
              GridItem() {
                this.chip(5)
              }.columnStart(2).columnEnd(2)

              GridItem() {
                this.chip(6)
              }.columnStart(0).columnEnd(2)

              GridItem() {
                this.chip(7)
              }.columnStart(0).columnEnd(1)
              GridItem() {
                this.chip(8)
              }.columnStart(2).columnEnd(2)

              GridItem() {
                this.chip(9)
              }.columnStart(0).columnEnd(0)
              GridItem() {
                this.chip(10)
              }.columnStart(1).columnEnd(1)
              GridItem() {
                this.chip(11)
              }.columnStart(2).columnEnd(2)

              GridItem() {
                this.chip(12)
              }.columnStart(0).columnEnd(0)
              GridItem() {
                this.chip(13)
              }.columnStart(1).columnEnd(1)
              GridItem() {
                this.chip(14)
              }.columnStart(2).columnEnd(2)
            }
            .columnsTemplate('1fr 1fr 1fr')
            // 6 行等分面板可用高度：胶囊随可用空间自适应，不会被裁
            .rowsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
            .height('100%')
            .columnsGap(6)
            .rowsGap(6)
            // 数据区不允许滑动、也不显示滚动条
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
            .enableScrollInteraction(false)
            .width('100%')
          }
        .width('100%')
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: this.barClearance + 10 })
      .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.cc_page_bg'))
  }

  private nextPassShort(): string {
    const info = this.selectedSat();
    if (info === null || info.pass === null) {
      return '下次 --';
    }
    return `下次 ${this.clock(info.pass.aosTime)}`;
  }

  private maybeName(): string {
    const info = this.selectedSat();
    return info === null ? '地图' : info.name;
  }

  private azimuthText(): string {
    const pos = this.currentPosition();
    return pos === null ? '方位 --' : `方位 ${toDegrees(pos.azimuth).toFixed(0)}°`;
  }

  private elevationText(): string {
    const pos = this.currentPosition();
    return pos === null ? '仰角 --' : `仰角 ${toDegrees(pos.elevation).toFixed(0)}°`;
  }

  private altitudeText(): string {
    const pos = this.currentPosition();
    return pos === null ? '高度 --' : `高度 ${pos.altitude.toFixed(0)}km`;
  }

  private rangeText(): string {
    const pos = this.currentPosition();
    return pos === null ? '距离 --' : `距离 ${pos.distance.toFixed(0)}km`;
  }

  /** 胶囊文本的“标签”部分 */
  private chipLabelOf(i: number): string {
    const t = this.chipValues.length > i ? this.chipValues[i] : '';
    const s = t.indexOf(' ');
    return s >= 0 ? t.substring(0, s) : t;
  }

  /** 胶囊文本的“值”部分 */
  private chipValueOf(i: number): string {
    const t = this.chipValues.length > i ? this.chipValues[i] : '';
    const s = t.indexOf(' ');
    return s >= 0 ? t.substring(s + 1) : '';
  }

  /** 刷新 15 个信息胶囊文本（每秒随定时器调用，保证实时）。 */
  private refreshChipValues(): void {
    this.chipValues = [
      this.azimuthText(),
      this.elevationText(),
      this.altitudeText(),
      this.rangeText(),
      this.rateText(),
      this.velocityText(),
      `星下 ${this.posText()}`,
      `QTH ${this.qthText()}`,
      this.nextPassShort(),
      this.periodText(),
      this.inclText(),
      this.eccnText(),
      this.meanmoText(),
      this.noradText(),
      this.stationText()
    ];
  }

  /** 等宽胶囊：绑定 @State 文本（index 为常量，规避 @Builder 按值传参不刷新的限制）。 */
  @Builder
  private chip(index: number) {
    Column({ space: 1 }) {
      Text(this.chipLabelOf(index))
        .fontSize(11)
        .fontColor($r('app.color.cc_text_muted'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.chipValueOf(index))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.cc_text_title'))
        .fontFeature('"tnum" 1')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .constraintSize({ minHeight: 30 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 4, right: 4 })
    .backgroundColor($r('app.color.cc_surface_muted'))
    .borderRadius(8)
  }
}