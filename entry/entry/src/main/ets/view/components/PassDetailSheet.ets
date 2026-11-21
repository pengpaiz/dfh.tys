import { SatelliteApp } from '../../common/SatelliteApp';
import { AppSettings } from '../../common/AppSettings';
import { SatPassEvent } from '../../domain/predict/SatPassFinder';
import { createOrbitalObject } from '../../domain/predict/OrbitalFactory';
import { SatOrbitalObject } from '../../domain/predict/OrbitalObject';
import { SatGeoPos } from '../../domain/predict/GeoPos';
import { RadarCanvas } from './RadarCanvas';
import { SatRadio } from '../../domain/model/SatRadio';
import { buildPassTrack, RadarTrackResult } from '../../domain/predict/RadarTrack';
import { sensor } from '@kit.SensorServiceKit';
import { promptAction } from '@kit.ArkUI';
import { DeviceOrientation } from '../../common/DeviceOrientation';
import { AudioRecorder } from '../../common/AudioRecorder';
import { RecordWaterfall } from './RecordWaterfall';
import { exportRecordingToDownload } from '../../service/RecordingExport';
import { common } from '@kit.AbilityKit';
import { toDegrees } from '../../common/utils/MathUtils';

const DOPPLER_REFRESH_MS = 5000;
const LIVE_REFRESH_MS = 1000;
const NO_LINK_TEXT = '- - . - -';

function degRad(rad: number): number {
  return toDegrees(rad);
}

function fmtMhz(hz: number): string {
  return `${(hz / 1000000).toFixed(4)} MHz`;
}

function fmtRange(lowHz: number, highHz: number): string {
  if (highHz <= 0 || highHz === lowHz) {
    return fmtMhz(lowHz);
  }
  return `${fmtMhz(lowHz)} - ${fmtMhz(highHz)}`;
}

function fmtOrNoLink(hasValue: boolean, lowHz: number, highHz: number): string {
  if (!hasValue || lowHz <= 0) {
    return NO_LINK_TEXT;
  }
  return fmtRange(lowHz, highHz);
}

export class FreqRowView {
  dir: string = '';
  hasValue: boolean = false;
  rawLowHz: number = -1;
  rawHighHz: number = -1;
  isDownlink: boolean = true;
  rawText: string = '';
  dopText: string = '';

  constructor(dir: string, hasValue: boolean, rawLowHz: number, rawHighHz: number, isDownlink: boolean,
              rawText: string, dopText: string) {
    this.dir = dir;
    this.hasValue = hasValue;
    this.rawLowHz = rawLowHz;
    this.rawHighHz = rawHighHz;
    this.isDownlink = isDownlink;
    this.rawText = rawText;
    this.dopText = dopText;
  }
}

/** 一个转发器：固定 RX(下行)/TX(上行) 两行。 */
export class FreqTxView {
  title: string = '';
  rows: FreqRowView[] = [];

  constructor(title: string, rows: FreqRowView[]) {
    this.title = title;
    this.rows = rows;
  }
}

export class FreqGroupView {
  mode: string = '';
  blocks: FreqTxView[] = [];

  constructor(mode: string, blocks: FreqTxView[]) {
    this.mode = mode;
    this.blocks = blocks;
  }
}

class FreqEntry {
  mode: string = '';
  title: string = '';
  downlow: number = -1;
  downhigh: number = -1;
  upLow: number = -1;
  upHigh: number = -1;
  downIsSet: boolean = false;
  upIsSet: boolean = false;

  constructor(mode: string, title: string, downlow: number, downhigh: number, upLow: number, upHigh: number,
              downIsSet: boolean, upIsSet: boolean) {
    this.mode = mode;
    this.title = title;
    this.downlow = downlow;
    this.downhigh = downhigh;
    this.upLow = upLow;
    this.upHigh = upHigh;
    this.downIsSet = downIsSet;
    this.upIsSet = upIsSet;
  }
}

export class PassDetailPayload {
  catnum: number = 0;
  name: string = '';
  color: string = '#E67E22';
  aosTime: number = 0;
  losTime: number = 0;
  maxElevationDeg: number = 0;
  durationMillis: number = 0;
  /** TCA 时的方位/仰角/距离/高度（存数值：轨道对象是全局共享的，共享位置实例会被后续计算覆盖） */
  tcaAzDeg: number = -999;
  tcaElevDeg: number = -999;
  tcaDistanceKm: number = 0;
  tcaAltitudeKm: number = 0;
  eclipsed: boolean = false;
  track: RadarTrackResult = new RadarTrackResult([], [], []);
  freqGroups: FreqGroupView[] = [];
  hasTransponders: boolean = false;
}

@Component
export struct PassDetailSheet {
  @Prop @Watch('onFreqSourceChanged') detail: PassDetailPayload = new PassDetailPayload();
  @State freqView: FreqGroupView[] = [];

  @State aimAzDeg: number = 0;
  @State aimTiltDeg: number = 0;
  @State liveAzDeg: number = -999;
  @State liveElevDeg: number = -999;
  @State liveInPass: boolean = false;
  @State liveProgress: number = 0;
  /** 详情分页：0=雷达图，1=收发频率 */
  @State pageIndex: number = 0;
  private pager: SwiperController = new SwiperController();
  /** 录音状态（供 UI 刷新）：是否在录、已录秒数、最近保存的文件名、按钮按压反馈 */
  @State recActive: boolean = false;
  @State recSeconds: number = 0;
  @State recSavedName: string = '';
  @State recPressed: boolean = false;
  private recTimerId: number = -1;
  private orientation: DeviceOrientation = new DeviceOrientation();
  private declinationDeg: number = 0;
  private orbital: SatOrbitalObject | null = null;
  private station: SatGeoPos = new SatGeoPos(0, 0);
  private freqTimerId: number = -1;
  private liveTimerId: number = -1;

  aboutToAppear(): void {
    this.startHeadingSensor();
    this.buildOrbital();
    this.refreshFreqView();
    this.updateLivePosition();
    this.freqTimerId = setInterval((): void => {
      this.refreshFreqView();
    }, DOPPLER_REFRESH_MS);
    this.liveTimerId = setInterval((): void => {
      this.updateLivePosition();
    }, LIVE_REFRESH_MS);
  }

  aboutToDisappear(): void {
    this.stopHeadingSensor();
    if (this.freqTimerId >= 0) {
      clearInterval(this.freqTimerId);
      this.freqTimerId = -1;
    }
    if (this.liveTimerId >= 0) {
      clearInterval(this.liveTimerId);
      this.liveTimerId = -1;
    }
    if (this.recTimerId >= 0) {
      clearInterval(this.recTimerId);
      this.recTimerId = -1;
    }
    // 退出详情页就停止并释放麦克风（录音必须前台进行）
    AudioRecorder.getInstance().releaseIfRecording();
    this.recActive = false;
  }

  // ---- 录音 ----

  /** 录音/停止：前台录制到本机，首次使用会申请麦克风权限。 */
  private async toggleRecord(): Promise<void> {
    const recorder = AudioRecorder.getInstance();
    if (recorder.isRecording()) {
      const name = await recorder.stop();
      this.stopRecTick();
      this.recSavedName = name;
      await this.exportRecording(name);
      return;
    }
    const granted = await AudioRecorder.ensurePermission(getContext(this));
    if (!granted) {
      promptAction.showToast({ message: '需要麦克风权限才能录音' });
      return;
    }
    try {
      const name = await recorder.start(getContext(this));
      this.recSavedName = name;
      this.startRecTick();
      promptAction.showToast({ message: '开始录音' });
    } catch (e) {
      promptAction.showToast({ message: '录音启动失败，请检查麦克风是否被占用' });
    }
  }

  /** 停止后把 WAV 导出到用户选择的下载目录；取消时仅保留应用内副本。 */
  private async exportRecording(name: string): Promise<void> {
    if (name.length === 0) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const path = `${ctx.filesDir}/recordings/${name}`;
    try {
      const uri = await exportRecordingToDownload(ctx, path, name);
      if (uri.length > 0) {
        promptAction.showToast({ message: `已保存到下载：${name}` });
      } else {
        promptAction.showToast({ message: `已保存在应用内：${name}` });
      }
    } catch (e) {
      promptAction.showToast({ message: `导出失败，已保存在应用内：${name}` });
    }
  }

  private startRecTick(): void {
    this.recActive = true;
    this.recSeconds = 0;
    if (this.recTimerId >= 0) {
      clearInterval(this.recTimerId);
    }
    this.recTimerId = setInterval((): void => {
      this.recSeconds = Math.floor(AudioRecorder.getInstance().elapsedMillis() / 1000);
    }, 1000);
  }

  private stopRecTick(): void {
    this.recActive = false;
    if (this.recTimerId >= 0) {
      clearInterval(this.recTimerId);
      this.recTimerId = -1;
    }
  }

  /** 录音时长 mm:ss */
  private recordTimeText(): string {
    const m = Math.floor(this.recSeconds / 60);
    const s = this.recSeconds % 60;
    return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
  }

  /** 雷达下方的录音按钮：与雷达同宽的长条，无文字 */
  @Builder
  private recordBar() {
    Row() {
      SymbolGlyph(this.recActive ? $r('sys.symbol.stop_circle_fill') : $r('sys.symbol.mic_fill'))
        .fontSize(22)
        .fontColor([Color.White])
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.recActive ? '#E53935' : $r('app.color.cc_primary'))
    .borderRadius(12)
    .scale({ x: this.recPressed ? 0.97 : 1, y: this.recPressed ? 0.97 : 1 })
    .onTouch((event: TouchEvent): void => {
      const down = event.type === TouchType.Down;
      this.getUIContext().animateTo({ duration: down ? 120 : 320, curve: Curve.EaseOut }, (): void => {
        this.recPressed = down;
      });
    })
    .onClick((): void => {
      this.toggleRecord();
    })
  }

  /** 录音按钮下方：瀑布图 + 录音时长 */
  @Builder
  private recordWavePanel() {
    Column({ space: 8 }) {
      Row() {
        Text('录音瀑布')
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
        Blank()
        Text(this.recordTimeText())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.recActive ? $r('app.color.cc_primary') : $r('app.color.cc_text_title'))
          .fontFeature('"tnum" 1')
      }
      .width('100%')
      .padding({ left: 12, right: 12 })

      RecordWaterfall()
        .width('100%')
        .layoutWeight(1)
        .borderRadius(6)
        .clip(true)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .backgroundColor($r('app.color.cc_card'))
    .border({ width: 1, color: $r('app.color.cc_border_strong'), radius: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  onFreqSourceChanged(): void {
    this.buildOrbital();
    this.refreshFreqView();
  }

  /** 每秒更新：正在过境时计算实时位置（黄色圆点）与过境进度。 */
  private updateLivePosition(): void {
    const now = Date.now();
    const inPass = now >= this.detail.aosTime && now <= this.detail.losTime;
    this.liveInPass = inPass;
    if (!inPass) {
      this.liveAzDeg = -999;
      this.liveElevDeg = -999;
      this.liveProgress = 0;
      return;
    }
    const dur = Math.max(1, this.detail.losTime - this.detail.aosTime);
    this.liveProgress = Math.max(0, Math.min(1, (now - this.detail.aosTime) / dur));
    if (this.orbital !== null) {
      const pos = this.orbital.getFullPosition(this.station, now);
      this.liveAzDeg = degRad(pos.azimuth);
      this.liveElevDeg = degRad(pos.elevation);
    }
  }

  static buildPayload(catnum: number, pass: SatPassEvent, color: string): PassDetailPayload {
    const app = SatelliteApp.getInstance();
    const store = app.getStore();
    const payload = new PassDetailPayload();
    payload.catnum = catnum;
    payload.color = color === '' ? '#E67E22' : color;
    payload.aosTime = pass.aosTime;
    payload.losTime = pass.losTime;
    payload.maxElevationDeg = pass.maxElevationDeg;
    payload.durationMillis = pass.durationMillis;
    const satData = store.getByCatnum(catnum);
    if (satData === null) {
      payload.name = `NORAD ${catnum}`;
      return payload;
    }
    payload.name = satData.name;
    const station = AppSettings.getStation();
    const obj = createOrbitalObject(satData);
    // TCA 时刻取 AOS/LOS 中点
    const tca = Math.floor((pass.aosTime + pass.losTime) / 2);
    const pos = obj.getFullPosition(station, tca);
    payload.tcaAzDeg = degRad(pos.azimuth);
    payload.tcaElevDeg = degRad(pos.elevation);
    payload.tcaDistanceKm = pos.distance;
    payload.tcaAltitudeKm = pos.altitude;
    payload.eclipsed = pos.eclipsed;
    payload.track = buildPassTrack(obj, station, pass, 1, 60);

    // 转发器（按模式分组，原始频率）
    const radios = store.getTranspondersFor(catnum);
    payload.hasTransponders = radios.length > 0;
    payload.freqGroups = PassDetailSheet.buildFreqGroups(radios);
    return payload;
  }

  private static buildFreqGroups(radios: SatRadio[]): FreqGroupView[] {
    const entries: FreqEntry[] = [];
    for (let i = 0; i < radios.length; i++) {
      const t = radios[i];
      const title = PassDetailSheet.radioTitle(t);
      entries.push(new FreqEntry(
        t.downlinkMode ?? t.uplinkMode ?? 'UNKNOWN',
        title,
        t.downlinkLow === null ? -1 : t.downlinkLow,
        t.downlinkHigh === null ? (t.downlinkLow === null ? -1 : t.downlinkLow) : t.downlinkHigh,
        t.uplinkLow === null ? -1 : t.uplinkLow,
        t.uplinkHigh === null ? (t.uplinkLow === null ? -1 : t.uplinkLow) : t.uplinkHigh,
        t.downlinkLow !== null,
        t.uplinkLow !== null));
    }
    entries.sort((a: FreqEntry, b: FreqEntry): number => a.mode.localeCompare(b.mode));
    const groups: FreqGroupView[] = [];
    for (let i = 0; i < entries.length; i++) {
      const e = entries[i];
      const rows: FreqRowView[] = [];
      const downRaw = fmtOrNoLink(e.downIsSet, e.downlow, e.downhigh);
      const upRaw = fmtOrNoLink(e.upIsSet, e.upLow, e.upHigh);
      rows.push(new FreqRowView('RX 下行', e.downIsSet, e.downlow, e.downhigh, true, downRaw, downRaw));
      rows.push(new FreqRowView('TX 上行', e.upIsSet, e.upLow, e.upHigh, false, upRaw, upRaw));
      const block = new FreqTxView(e.title, rows);
      let group: FreqGroupView | null = null;
      for (let g = 0; g < groups.length; g++) {
        if (groups[g].mode === e.mode) {
          group = groups[g];
          break;
        }
      }
      if (group === null) {
        group = new FreqGroupView(e.mode, []);
        groups.push(group);
      }
      group.blocks.push(block);
    }
    return groups;
  }

  private static radioTitle(t: SatRadio): string {
    const inv = t.isInverted ? 'INV: ' : '';
    const base = t.info.length > 0 ? t.info : 'Transceiver';
    const mode = `${t.downlinkMode ?? '-'}/${t.uplinkMode ?? '-'}`;
    return `${inv}${base} (${mode})`;
  }

  private buildOrbital(): void {
    const app = SatelliteApp.getInstance();
    const sat = app.getStore().getByCatnum(this.detail.catnum);
    if (sat !== null) {
      this.orbital = createOrbitalObject(sat);
    } else {
      this.orbital = null;
    }
    this.station = AppSettings.getStation();
  }

  private refreshFreqView(): void {
    const src = this.detail.freqGroups;
    const views: FreqGroupView[] = [];
    const now = Date.now();
    // 所有转发器行都用同一时刻的多普勒，位置只算一次（此前每行各算一次，转发器多时浪费明显）
    const pos = this.orbital !== null ? this.orbital.getFullPosition(this.station, now) : null;
    for (let i = 0; i < src.length; i++) {
      const blocks: FreqTxView[] = [];
      for (let j = 0; j < src[i].blocks.length; j++) {
        const b = src[i].blocks[j];
        const rows: FreqRowView[] = [];
        for (let k = 0; k < b.rows.length; k++) {
          const r = b.rows[k];
          let dopText = r.rawText;
          if (r.hasValue && pos !== null) {
            const low = r.isDownlink ? pos.getDownlinkFreq(r.rawLowHz) : pos.getUplinkFreq(r.rawLowHz);
            const high = r.isDownlink ? pos.getDownlinkFreq(r.rawHighHz) : pos.getUplinkFreq(r.rawHighHz);
            dopText = fmtRange(low, high);
          }
          rows.push(new FreqRowView(r.dir, r.hasValue, r.rawLowHz, r.rawHighHz, r.isDownlink, r.rawText, dopText));
        }
        blocks.push(new FreqTxView(b.title, rows));
      }
      views.push(new FreqGroupView(src[i].mode, blocks));
    }
    this.freqView = views;
  }

  private startHeadingSensor(): void {
    this.orientation.start((azimuth: number, pitch: number): void => {
      this.aimAzDeg = (azimuth + this.declinationDeg + 360) % 360;
      this.aimTiltDeg = pitch;
    });
    this.fetchDeclination();
  }

  private stopHeadingSensor(): void {
    this.orientation.stop();
  }

  private fetchDeclination(): void {
    const station = AppSettings.getStation();
    const loc: sensor.LocationOptions = {
      latitude: station.latitude,
      longitude: station.longitude,
      altitude: station.altitude
    };
    sensor.getGeomagneticInfo(loc, Date.now()).then((resp: sensor.GeomagneticResponse): void => {
      this.declinationDeg = resp.deflectionAngle;
    }).catch(() => {
    });
  }

  private clock(millis: number): string {
    const d = new Date(millis);
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private dateLabel(millis: number): string {
    const d = new Date(millis);
    const today = new Date();
    if (d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() && d.getDate() === today.getDate()) {
      return '今天';
    }
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.detail.name)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.cc_text_title'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`NORAD ${this.detail.catnum}`)
          .fontSize(12)
          .fontColor(this.detail.color as ResourceColor)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      this.passTimesRow()

      if (this.liveInPass) {
        this.liveProgressBar()
      }

      // 分页切换：第一页雷达图，第二页收发频率
      Row({ space: 8 }) {
        this.pageTab('雷达', 0)
        this.pageTab('收发频率', 1)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      Swiper(this.pager) {
        // 第一页：放大雷达图 + 录音条
        Column({ space: 10 }) {
            Column({ space: 10 }) {
              Stack() {
              RadarCanvas({
                azimuthDeg: this.detail.tcaAzDeg,
                elevationDeg: this.detail.tcaElevDeg,
                track: this.detail.track,
                trackColor: this.detail.color,
                eclipsed: this.detail.eclipsed,
                headingAzDeg: this.aimAzDeg,
                headingTiltDeg: this.aimTiltDeg,
                liveAzDeg: this.liveAzDeg,
                liveElevDeg: this.liveElevDeg
              })
                .width('100%')
                .height('100%')

              // 四角读数叠在雷达盘上层（方位/仰角/高度/距离）
              Column() {
                Row() {
                  this.cornerStat('方位', `${this.detail.tcaAzDeg.toFixed(1)}°`, false)
                  Blank()
                  this.cornerStat('仰角', `${this.detail.tcaElevDeg.toFixed(1)}°`, true)
                }
                .width('100%')

                Blank()

                Row() {
                  this.cornerStat('高度', `${this.detail.tcaAltitudeKm.toFixed(0)} km`, false)
                  Blank()
                  this.cornerStat('距离', `${this.detail.tcaDistanceKm.toFixed(0)} km`, true)
                }
                .width('100%')
              }
              .width('100%')
              .height('100%')
              .padding(14)
              .hitTestBehavior(HitTestMode.None)
            }
            .width('100%')
            .aspectRatio(1)
            .padding(2)
            .backgroundColor($r('app.color.color_panel_radar'))
            .border({ width: 1, color: $r('app.color.cc_border_strong'), radius: 12 })

            // 录音：贴在雷达正下方（不遮挡雷达绘制），把通联音频录到本机
            this.recordBar()
            }
            .width('100%')

            // 瀑布图与录音时长：填满下方剩余空间
            this.recordWavePanel()
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })

        // 第二页：收发频率
        Scroll() {
          Column() {
            this.freqCard()
          }
          .width('100%')
          // 预留右侧滚动条宽度，避免悬浮滚动条压住右对齐的频率数值
          .padding({ left: 12, right: 20, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.color_panel_data'))
          .border({ width: 1, color: $r('app.color.cc_border_strong'), radius: 12 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 8 })
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .layoutWeight(1)
      .width('100%')
      .loop(false)
      .indicator(false)
      .duration(200)
      // 动画一开始就切换页签高亮，避免等滑动结束才响应
      .onAnimationStart((index: number, targetIndex: number): void => {
        this.selectPage(targetIndex);
      })
      .onChange((index: number): void => {
        this.selectPage(index);
      })
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 切换页签高亮：带 180ms 缓动，滑动与点击共用 */
  private selectPage(index: number): void {
    if (this.pageIndex === index) {
      return;
    }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
      this.pageIndex = index;
    });
  }

  /** 顶部分页胶囊：选中态用主色填充 */
  @Builder
  private pageTab(label: string, index: number) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.pageIndex === index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.pageIndex === index ? $r('app.color.cc_on_primary') : $r('app.color.cc_text_muted'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.pageIndex === index ? $r('app.color.cc_primary') : $r('app.color.cc_surface_muted'))
      .borderRadius(12)
      .onClick((): void => {
        if (this.pageIndex !== index) {
          this.selectPage(index);
          this.pager.changeIndex(index);
        }
      })
  }
  /** 雷达盘四角读数：标签在上、数值在下，左侧左对齐、右侧右对齐 */
  @Builder
  private cornerStat(label: string, value: string, alignRight: boolean) {
    Column({ space: 1 }) {
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.cc_text_muted'))
      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.cc_text_title'))
        .fontFeature('"tnum" 1')
    }
    .alignItems(alignRight ? HorizontalAlign.End : HorizontalAlign.Start)
  }

  @Builder
  private freqCard() {
    Column({ space: 10 }) {
      Row() {
        Text('收发频率')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.cc_text_title'))
        Blank()
        Text('多普勒每 5s 刷新')
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
      }
      .width('100%')

      if (!this.detail.hasTransponders) {
        Text('暂无转发器数据（可从“国内数据下载”获取）')
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
      } else {
        Row({ space: 6 }) {
          Text('链路').fontSize(12).fontColor($r('app.color.cc_text_muted')).width(64)
          Text('原始 (MHz)')
            .fontSize(12)
            .fontColor($r('app.color.cc_text_muted'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
          Text('多普勒 (MHz)')
            .fontSize(12)
            .fontColor($r('app.color.cc_text_muted'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .padding({ left: 12, right: 12 })

        // 每种收发模式独立成一个模块卡片
        ForEach(this.freqView, (g: FreqGroupView) => {
          Column({ space: 8 }) {
            Text(g.mode)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.cc_accent_text'))
            ForEach(g.blocks, (blk: FreqTxView) => {
              Column({ space: 4 }) {
                Text(blk.title)
                  .fontSize(12)
                  .fontColor($r('app.color.cc_text_muted'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                ForEach(blk.rows, (r: FreqRowView) => {
                  Row({ space: 6 }) {
                    Text(r.dir).fontSize(12).fontColor($r('app.color.cc_text_muted')).width(64)
                    Text(r.rawText)
                      .fontSize(12)
                      .fontColor(r.hasValue ? $r('app.color.cc_text_title') : $r('app.color.cc_text_muted'))
                      .layoutWeight(1)
                      .textAlign(TextAlign.End)
                    Text(r.dopText)
                      .fontSize(12)
                      .fontColor(r.hasValue ? $r('app.color.cc_accent_text') : $r('app.color.cc_text_muted'))
                      .layoutWeight(1)
                      .textAlign(TextAlign.End)
                  }
                  .width('100%')
                }, (r: FreqRowView): string => r.dir)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(10)
              .backgroundColor($r('app.color.cc_page_bg'))
              .borderRadius(8)
            }, (blk: FreqTxView, idx: number): string => blk.title + idx)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor($r('app.color.cc_card'))
          .border({ width: 1, color: $r('app.color.cc_border_strong'), radius: 10 })
        }, (g: FreqGroupView): string => g.mode)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private liveProgressBar() {
    Row() {
      Column({ space: 4 }) {
      Row() {
        Text('● 正在过境')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.cc_warning'))
        Blank()
        Text(`${Math.round(this.liveProgress * 100)}%`)
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
      }
      .width('100%')

      Progress({ value: Math.round(this.liveProgress * 100), total: 100, type: ProgressType.Linear })
        .width('100%')
        .color($r('app.color.cc_warning'))
        .backgroundColor($r('app.color.cc_surface_muted'))
        .height(6)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.cc_card'))
    .borderRadius(8)
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
  }

  @Builder
  private passTimesRow() {
    Row() {
      Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('AOS（捕获）').fontSize(12).fontColor($r('app.color.cc_text_muted'))
        Text(`${this.dateLabel(this.detail.aosTime)} ${this.clock(this.detail.aosTime)}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.cc_text_title'))
          .fontFeature('"tnum" 1')
      }
      Blank()
      Column({ space: 2 }) {
        Text('LOS（消失）').fontSize(12).fontColor($r('app.color.cc_text_muted'))
        Text(`${this.dateLabel(this.detail.losTime)} ${this.clock(this.detail.losTime)}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.cc_text_title'))
          .fontFeature('"tnum" 1')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.cc_card'))
    .border({ width: 1, color: $r('app.color.cc_border_strong'), radius: 12 })
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
  }
}