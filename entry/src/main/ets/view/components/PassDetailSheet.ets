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
      promptAction.showToast({ message: `已保存 ${name}` });
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
    this.recSeconds = 0;
    if (this.recTimerId >= 0) {
      clearInterval(this.recTimerId);
      this.recTimerId = -1;
    }
  }

  private recTimeText(): string {
    const m = Math.floor(this.recSeconds / 60);
    const s = this.recSeconds % 60;
    return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
  }

  /** 状态副标题：未录 / 录制中提示 / 上次保存结果 */
  private recHintText(): string {
    if (this.recActive) {
      return `录制中 ${this.recTimeText()} · 再点一次停止`;
    }
    if (this.recSavedName.length > 0) {
      return `已保存 ${this.recSavedName}`;
    }
    return '把本次通联音频录到本机';
  }

  /** 雷达下方的录音条 */
  @Builder
  private recordBar() {
    Row({ space: 12 }) {
      // 圆形录音按钮：录制中显示停止图标 + 红色底
      Column() {
        SymbolGlyph(this.recActive ? $r('sys.symbol.stop_circle_fill') : $r('sys.symbol.mic_fill'))
          .fontSize(18)
          .fontColor([Color.White])
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.recActive ? '#E53935' : $r('app.color.cc_primary'))
      .scale({ x: this.recPressed ? 0.9 : 1, y: this.recPressed ? 0.9 : 1 })
      .onTouch((event: TouchEvent): void => {
        const down = event.type === TouchType.Down;
        this.getUIContext().animateTo({ duration: down ? 120 : 320, curve: Curve.EaseOut }, (): void => {
          this.recPressed = down;
        });
      })
      .onClick((): void => {
        this.toggleRecord();
      })

      Column({ space: 3 }) {
        Text(this.recActive ? '录音中' : '录音')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.recActive ? '#E53935' : $r('app.color.cc_text_title'))
        Text(this.recHintText())
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(10)
    .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
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
    Column({ space: 18 }) {
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

      this.passTimesRow()

      if (this.liveInPass) {
        this.liveProgressBar()
      }

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
        .padding(10)
        .backgroundColor($r('app.color.color_panel_radar'))
        .borderRadius(12)

      // 录音：贴在雷达正下方（不遮挡雷达绘制），把通联音频录到本机
      this.recordBar()

      Scroll() {
        Column({ space: 14 }) {
          this.statsGrid()

          this.freqCard()
        }
        .width('100%')
        // 预留右侧滚动条宽度，避免悬浮滚动条压住右对齐的频率数值
        .padding({ left: 12, right: 20, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.color_panel_data'))
        .borderRadius(12)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private statsGrid() {
    Grid() {
      GridItem() {
        this.statBox('方位', `${this.detail.tcaAzDeg.toFixed(0)}°`)
      }
      GridItem() {
        this.statBox('仰角', `${this.detail.tcaElevDeg.toFixed(0)}°`)
      }
      GridItem() {
        this.statBox('距离', `${this.detail.tcaDistanceKm.toFixed(0)} km`)
      }
      GridItem() {
        this.statBox('高度', `${this.detail.tcaAltitudeKm.toFixed(0)} km`)
      }
      GridItem() {
        this.statBox('最高仰角', `${this.detail.maxElevationDeg.toFixed(0)}°`)
      }
      GridItem() {
        this.statBox('时长', `${Math.round(this.detail.durationMillis / 60000)} min`)
      }
    }
    .columnsTemplate('1fr 1fr 1fr')
    .rowsGap(8)
    .columnsGap(8)
    .width('100%')
  }

  @Builder
  private statBox(label: string, value: string) {
    Column({ space: 3 }) {
      Text(label).fontSize(12).fontColor($r('app.color.cc_text_muted'))
      Text(value).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.cc_text_title'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor($r('app.color.cc_page_bg'))
    .borderRadius(8)
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

        ForEach(this.freqView, (g: FreqGroupView) => {
          Column({ space: 6 }) {
            Text(g.mode)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.cc_accent_text'))
            ForEach(g.blocks, (blk: FreqTxView) => {
              Column({ space: 2 }) {
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
            }, (blk: FreqTxView, idx: number): string => blk.title + idx)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (g: FreqGroupView): string => g.mode)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.cc_card'))
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private liveProgressBar() {
    Column({ space: 4 }) {
      Row() {
        Text('● 正在过境')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E6A23C')
        Blank()
        Text(`${Math.round(this.liveProgress * 100)}%`)
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
      }
      .width('100%')

      Progress({ value: Math.round(this.liveProgress * 100), total: 100, type: ProgressType.Linear })
        .width('100%')
        .color('#E6A23C')
        .backgroundColor('#3D3D3D')
        .height(6)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.cc_card'))
    .borderRadius(8)
  }

  @Builder
  private passTimesRow() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('AOS（捕获）').fontSize(12).fontColor($r('app.color.cc_text_muted'))
        Text(`${this.dateLabel(this.detail.aosTime)} ${this.clock(this.detail.aosTime)}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.cc_text_title'))
      }
      Blank()
      Column({ space: 2 }) {
        Text('LOS（消失）').fontSize(12).fontColor($r('app.color.cc_text_muted'))
        Text(`${this.dateLabel(this.detail.losTime)} ${this.clock(this.detail.losTime)}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.cc_text_title'))
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.cc_card'))
    .borderRadius(8)
  }
}