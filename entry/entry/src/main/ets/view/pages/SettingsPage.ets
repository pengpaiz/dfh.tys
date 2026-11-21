import { promptAction } from '@kit.ArkUI';
import { qthToPosition, positionToQth } from '../../domain/qth/QthConverter';
import { AppSettings, WINDOW_PRESETS, CUSTOM_RESULT_FAIL, CUSTOM_RESULT_NONE, CUSTOM_RESULT_OK } from '../../common/AppSettings';
import { Locator } from '../../common/Locator';
import { SatelliteApp } from '../../common/SatelliteApp';
import { SelectedSats } from '../../common/SelectedSats';
import { SatelliteDownloader } from '../../data/downloader/SatelliteDownloader';
import { ENTER_SCALE, PRESS_IN_MS, PRESS_OUT_MS, PRESS_SCALE } from '../components/PressFx';
import { ElevationSlider } from '../components/ElevationSlider';
import { KEY_BAR_CLEARANCE, TAB_BAR_CLEARANCE } from '../../common/LayoutMetrics';
import { Favorites } from '../../common/Favorites';
import { AudioRecorder } from '../../common/AudioRecorder';

/** 预测窗口可用上限（小时）：与过境计算窗口一致（见 PassCache.PASS_CACHE_HOURS） */
const MAX_WINDOW_HOURS = 48;

@Component
export struct SettingsPage {
  @State latText: string = '48.2';
  @State lonText: string = '16.37';
  @State altText: string = '0';
  @State qthText: string = '';
  @State customWindowText: string = '';
  @State customSelected: boolean = false;
  @State satCount: number = 0;
  @State transCount: number = 0;
  @State minElevation: number = 5;
  @State pressedBtn: string = '';
  @State btnEntered: boolean = false;
  /** 底部预留（由 Index 按栏高+导航条避让算出后发布） */
  @StorageProp(KEY_BAR_CLEARANCE) barClearance: number = TAB_BAR_CLEARANCE;
  @State tleUrlText: string = '';
  @State transUrlText: string = '';
  @State updating: boolean = false;
  /** 预测窗口数值切换动画进度 0→1 */
  @State winFx: number = 1;
  @StorageLink('settings_window_hours') windowHours: number = 24;
  @StorageProp('station_version') @Watch('onStationChanged') stationVersion: number = 0;
  /** 数据源使用情况（随更新实时刷新显示） */
  @StorageProp('data_source_last_url') lastSrcUrl: string = '';
  @StorageProp('data_source_custom_time') srcCustomTime: number = 0;
  /** 自定义地址最近一次使用结果：0 未更新 / 1 成功 / 2 失败 */
  @StorageProp('data_source_custom_result') srcCustomResult: number = CUSTOM_RESULT_NONE;
  /** 内置离线数据（打包快照）的版本时间 */
  @StorageProp('builtin_snapshot_time') builtinSnapshotTime: number = 0;
  /** 已保存的自定义 TLE 地址（响应式）：保存后"当前模式"实时刷新 */
  @StorageProp('settings_custom_tle_url') customTleUrl: string = '';
  private wasLoaded: boolean = false;
  private app: SatelliteApp = SatelliteApp.getInstance();

  aboutToAppear(): void {
    if (this.wasLoaded) {
      return;
    }
    this.wasLoaded = true;
    const station = AppSettings.getStation();
    this.latText = station.latitude.toFixed(4);
    this.lonText = station.longitude.toFixed(4);
    this.altText = station.altitude.toFixed(0);
    this.qthText = positionToQth(station.latitude, station.longitude) ?? '';
    this.minElevation = AppSettings.getMinElevation();
    this.tleUrlText = AppSettings.getCustomTleUrl();
    this.transUrlText = AppSettings.getCustomTransponderUrl();
    this.refreshCounts();
  }

  /** 站址被静默更新（启动定位）或别处修改后，同步已显示的内容，避免停留过期值。 */
  onStationChanged(): void {
    const station = AppSettings.getStation();
    this.latText = station.latitude.toFixed(4);
    this.lonText = station.longitude.toFixed(4);
    this.altText = station.altitude.toFixed(0);
    this.qthText = positionToQth(station.latitude, station.longitude) ?? this.qthText;
  }

  private refreshCounts(): void {
    this.satCount = this.app.getStore().getAll().length;
    this.transCount = this.app.getStore().getTransponders().length;
  }

  private selCountStr(): string {
    return String(SelectedSats.getCats().length);
  }

  private applyQth(): void {
    if (this.qthText.trim().length === 0) {
      return;
    }
    const pos = qthToPosition(this.qthText);
    if (pos === null) {
      promptAction.showToast({ message: 'QTH 定位器无效' });
      return;
    }
    this.latText = pos.latitude.toFixed(4);
    this.lonText = pos.longitude.toFixed(4);
    this.autoSaveStation();
  }

  /** 把输入框恢复成当前生效的站址。 */
  private revertStationFields(): void {
    const s = AppSettings.getStation();
    this.latText = s.latitude.toFixed(4);
    this.lonText = s.longitude.toFixed(4);
    this.altText = s.altitude.toFixed(0);
  }

  private async locate(): Promise<void> {
    promptAction.showToast({ message: '正在定位…' });
    const pos = await Locator.getCurrentPosition(getContext(this), true);
    if (pos === null) {
      promptAction.showToast({ message: '定位失败，请检查定位权限/开关' });
      return;
    }
    this.latText = pos.latitude.toFixed(4);
    this.lonText = pos.longitude.toFixed(4);
    // 海拔不可信时沿用已保存的值，不要用 0/粗差覆盖
    const alt = Locator.altitudeIsUsable(pos.altitude) ? pos.altitude : AppSettings.getStation().altitude;
    this.altText = alt.toFixed(0);
    AppSettings.setStation(pos.latitude, pos.longitude, alt, true);
    this.qthText = positionToQth(pos.latitude, pos.longitude) ?? '';
    const altHint = Locator.altitudeIsUsable(pos.altitude) ? '' : '（海拔沿用原值）';
    promptAction.showToast({ message: `已定位：${this.qthText}${altHint}` });
  }

  // ---- 自定义数据源 ----

  /** 当前实际生效的渠道（按最近一次成功更新判断） */
  private sourceModeText(): string {
    const custom = this.customTleUrl;
    if (custom.length === 0) {
      return '内置离线数据';
    }
    if (this.lastSrcUrl.length === 0) {
      return '自定义地址（还没成功更新过）';
    }
    if (this.lastSrcUrl === custom) {
      return '自定义地址';
    }
    return '自定义地址';
  }

  private customTimeText(): string {
    if (this.customTleUrl.length === 0) {
      return '未填写';
    }
    if (this.srcCustomResult === CUSTOM_RESULT_OK) {
      return `成功 · ${AppSettings.formatTime(this.srcCustomTime)}`;
    }
    if (this.srcCustomResult === CUSTOM_RESULT_FAIL) {
      return '失败';
    }
    return '未更新过';
  }

  private async saveAndUpdateSource(): Promise<void> {
    if (this.updating) {
      return;
    }
    const tle = this.tleUrlText.trim();
    const trans = this.transUrlText.trim();
    // 本应用离线优先：没填地址就不联网，直接用内置离线数据
    if (tle.length === 0) {
      promptAction.showToast({ message: '未填写数据地址：当前使用内置离线数据' });
      return;
    }
    if (!SatelliteDownloader.isUsableUrl(tle)) {
      promptAction.showToast({ message: '数据地址需以 http:// 或 https:// 开头' });
      return;
    }
    if (trans.length > 0 && !SatelliteDownloader.isUsableUrl(trans)) {
      promptAction.showToast({ message: '转发器地址需以 http:// 或 https:// 开头' });
      return;
    }
    AppSettings.setCustomTleUrl(tle);
    AppSettings.setCustomTransponderUrl(trans);
    this.updating = true;
    promptAction.showToast({ message: '正在更新…' });
    try {
      const count = await this.app.downloadAndStore();
      try {
        await this.app.downloadTranspondersAndStore();
      } catch (e) {
        // 转发器可选，失败不影响卫星数据
      }
      this.refreshCounts();
      promptAction.showToast({ message: `已更新 ${count} 颗卫星` });
    } catch (e) {
      promptAction.showToast({ message: '更新失败，请检查地址与网络' });
    }
    this.updating = false;
  }

  private resetSource(): void {
    AppSettings.setCustomTleUrl('');
    AppSettings.setCustomTransponderUrl('');
    this.tleUrlText = '';
    this.transUrlText = '';
    promptAction.showToast({ message: '已清除自定义地址，改用内置离线数据' });
  }

  private validLatLon(lat: number, lon: number): boolean {
    return !Number.isNaN(lat) && !Number.isNaN(lon) && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
  }

  /** 输入完成即自动保存；非法则回滚输入框并提示，不写入站址。 */
  private autoSaveStation(): void {
    if (this.latText.trim().length === 0 || this.lonText.trim().length === 0) {
      this.revertStationFields();
      promptAction.showToast({ message: '经纬度不能为空，已还原' });
      return;
    }
    const lat = Number(this.latText);
    const lon = Number(this.lonText);
    const alt = Number(this.altText);
    if (!this.validLatLon(lat, lon)) {
      this.revertStationFields();
      promptAction.showToast({ message: '经纬度无效，已还原为上次保存的值' });
      return;
    }
    AppSettings.setStation(lat, lon, Number.isNaN(alt) ? 0 : alt, true);
    const qth = positionToQth(lat, lon);
    if (qth !== null) {
      this.qthText = qth;
    }
    promptAction.showToast({ message: '站址已保存' });
  }

  /** 已生效（AppStorage 里）的站址，用于给自动保存直观反馈。 */
  private savedStationText(): string {
    const s = AppSettings.getStation();
    const qth = AppStorage.get<string>('station_qth') ?? '';
    const suffix = qth.length > 0 ? `  ${qth}` : '';
    return `${s.latitude.toFixed(4)}, ${s.longitude.toFixed(4)}, ${s.altitude.toFixed(0)}m${suffix}`;
  }

  private onWindowChange(v: number): void {
    this.windowHours = v;
  }

  // ---- 按钮动画 ----

  /**
   * 预测窗口切换动画：与卫星页选择动画同一套（320ms + Friction）。
   * 先瞬回 0（duration=0 不产生动画），下一帧再动画到 1。
   */
  private playWinFx(): void {
    this.getUIContext().animateTo({ duration: 0, curve: Curve.Linear }, (): void => {
      this.winFx = 0;
    });
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
        this.winFx = 1;
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

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('设置').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.cc_text_title'))
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 6 })

      Scroll() {
        Column({ space: 14 }) {
          this.sectionData()
          this.sectionForecast()
          this.sectionStation()
          this.sectionCustomSource()
          this.currentSummary()
          this.sectionPrivacy()
          this.sectionAbout()
        }
        .width('100%')
        // 底部预留悬浮胶囊栏空间，保证最后一个卡片能滚到胶囊上方
        .padding({ left: 16, right: 16, bottom: this.barClearance })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.cc_page_bg'))
    .onAppear((): void => {
      this.getUIContext().animateTo({ duration: PRESS_OUT_MS, curve: Curve.EaseOut }, (): void => {
        this.btnEntered = true;
      });
    })
  }

  @Builder
  private sectionData() {
    Column({ space: 8 }) {
      Row() {
        Text('数据状态').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.cc_text_title'))
      }
      .width('100%')

      Grid() {
        GridItem() {
          this.dataBox('卫星', `${this.satCount}`)
        }
        GridItem() {
          this.dataBox('转发器', `${this.transCount}`)
        }
        GridItem() {
          this.dataBox('跟踪中', this.selCountStr())
        }
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .width('100%')

        Button('重载内置数据')
        .width('100%')
        .fontSize(14)
        .scale({ x: this.pressScale('set-refresh'), y: this.pressScale('set-refresh') })
        .onTouch((event: TouchEvent): void => {
          this.onBtnTouch('set-refresh', event);
        })
        .onClick((): void => {
          this.reloadData()
        })
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private sectionCustomSource() {
    Column({ space: 10 }) {
      Row() {
        Text('自定义数据源').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.cc_text_title'))
        Blank()
        if (this.updating) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.cc_primary'))
        }
      }
      .width('100%')

      // 当前使用的模式 + 两个渠道各自最近一次成功更新的时间
      Row() {
        Text('当前模式')
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
        Blank()
        Text(this.sourceModeText())
          .fontSize(12)
          .fontColor($r('app.color.cc_accent_text'))
      }
      .width('100%')

      Row() {
        Text('自定义地址更新')
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
        Blank()
        Text(this.customTimeText())
          .fontSize(12)
          .fontColor($r('app.color.cc_text_title'))
      }
      .width('100%')

      TextInput({ placeholder: '卫星', text: this.tleUrlText })
        .width('100%')
        .height(38)
        .fontSize(12)
        .type(InputType.Normal)
        .onChange((v: string): void => {
          this.tleUrlText = v
        })

      TextInput({ placeholder: '接收器', text: this.transUrlText })
        .width('100%')
        .height(38)
        .fontSize(12)
        .type(InputType.Normal)
        .onChange((v: string): void => {
          this.transUrlText = v
        })

      Row({ space: 8 }) {
        Button(this.updating ? '更新中…' : '保存并更新')
          .layoutWeight(1)
          .fontSize(14)
          .backgroundColor($r('app.color.cc_primary'))
          .enabled(!this.updating)
          .opacity(this.updating ? 0.6 : 1)
          .scale({ x: this.pressScale('set-src-save'), y: this.pressScale('set-src-save') })
          .onTouch((event: TouchEvent): void => {
            this.onBtnTouch('set-src-save', event);
          })
          .onClick((): void => {
            this.saveAndUpdateSource()
          })
        Button('清除地址')
          .fontSize(14)
          .enabled(!this.updating)
          .opacity(this.updating ? 0.6 : 1)
          .scale({ x: this.pressScale('set-src-reset'), y: this.pressScale('set-src-reset') })
          .onTouch((event: TouchEvent): void => {
            this.onBtnTouch('set-src-reset', event);
          })
          .onClick((): void => {
            this.resetSource()
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private dataBox(label: string, valueTxt: string) {
    Column({ space: 3 }) {
      Text(valueTxt).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.cc_accent_text'))
      Text(label).fontSize(12).fontColor($r('app.color.cc_text_muted'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor($r('app.color.cc_page_bg'))
    .borderRadius(8)
  }

  /** 重载内置离线数据：不联网，随时可用（原来这里需要联网更新，无网络时会失败）。 */
  private async reloadData(): Promise<void> {
    if (this.updating) {
      return;
    }
    this.updating = true;
    promptAction.showToast({ message: '正在重载内置数据…' });
    try {
      const count = await this.app.reloadFromSnapshot();
      this.refreshCounts();
      promptAction.showToast({
        message: count > 0 ? `已重载内置离线数据（${count} 颗卫星）` : '内置数据重载失败，已保留原有数据'
      });
    } catch (e) {
      promptAction.showToast({ message: '内置数据重载失败，已保留原有数据' });
    }
    this.updating = false;
  }

  @Builder
  private sectionStation() {
    Column({ space: 10 }) {
      Row() {
        Text('观测站位置').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.cc_text_title'))
        Blank()
        Text(this.liveQth())
          .fontSize(12)
          .fontColor($r('app.color.cc_accent_text'))
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('纬度').fontSize(14).fontColor($r('app.color.cc_text_muted'))
        TextInput({ placeholder: '纬度', text: this.latText })
          .layoutWeight(1)
          .type(InputType.NUMBER_DECIMAL)
          .onChange((v: string): void => {
            this.latText = v
          })
          .onEditChange((isEditing: boolean): void => {
            if (!isEditing) {
              this.autoSaveStation()
            }
          })
      }
      Row({ space: 10 }) {
        Text('经度').fontSize(14).fontColor($r('app.color.cc_text_muted'))
        TextInput({ placeholder: '经度', text: this.lonText })
          .layoutWeight(1)
          .type(InputType.NUMBER_DECIMAL)
          .onChange((v: string): void => {
            this.lonText = v
          })
          .onEditChange((isEditing: boolean): void => {
            if (!isEditing) {
              this.autoSaveStation()
            }
          })
      }
      Row({ space: 10 }) {
        Text('海拔(m)').fontSize(14).fontColor($r('app.color.cc_text_muted'))
        TextInput({ placeholder: '海拔', text: this.altText })
          .layoutWeight(1)
          .type(InputType.NUMBER_DECIMAL)
          .onChange((v: string): void => {
            this.altText = v
          })
          .onEditChange((isEditing: boolean): void => {
            if (!isEditing) {
              this.autoSaveStation()
            }
          })
      }

      Divider().color($r('app.color.cc_border'))

      Text('QTH 定位器').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.cc_text_title'))
      Row({ space: 8 }) {
        TextInput({ placeholder: '如 JN88XA', text: this.qthText })
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.qthText = v
          })
          .onEditChange((isEditing: boolean): void => {
            if (!isEditing) {
              this.applyQth()
            }
          })
        Button('填充坐标')
          .fontSize(14)
          .scale({ x: this.pressScale('set-qth'), y: this.pressScale('set-qth') })
          .onTouch((event: TouchEvent): void => {
            this.onBtnTouch('set-qth', event);
          })
          .onClick((): void => {
            this.applyQth()
          })
      }
      .width('100%')

      Button('📌 定位到当前位置')
        .width('100%')
        .fontSize(14)
        .backgroundColor($r('app.color.cc_primary'))
        .scale({ x: this.pressScale('set-locate'), y: this.pressScale('set-locate') })
        .onTouch((event: TouchEvent): void => {
          this.onBtnTouch('set-locate', event);
        })
        .onClick((): void => {
          this.locate()
        })
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private sectionForecast() {
    Column({ space: 10 }) {
      Text('过境预报').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.cc_text_title'))
      // 滑动条拆成独立组件：拖动只重绘它自己，松手才提交（避免逐帧重建整页）
      ElevationSlider({
        initialValue: this.minElevation,
        onCommit: (v: number): void => {
          this.minElevation = v;
          AppSettings.setMinElevation(v);
        }
      })

      Divider().color($r('app.color.cc_border'))

      Row() {
        Text('预测窗口').fontSize(14).fontColor($r('app.color.cc_text_title'))
        Blank()
        Text(`${this.windowHours} h`)
          .fontSize(14)
          .fontColor($r('app.color.cc_accent_text'))
          // 数值随切换动画一起淡入并轻微上浮
          .opacity(0.15 + 0.85 * this.winFx)
          .translate({ y: 6 * (1 - this.winFx) })
      }
      .width('100%')

      Row({ space: 6 }) {
        ForEach(WINDOW_PRESETS, (h: number) => {
          Text(`${h}h`)
            .fontSize(14)
            .fontColor((!this.customSelected && this.windowHours === h) ? $r('app.color.cc_on_primary') : $r('app.color.cc_text_muted'))
            .backgroundColor((!this.customSelected && this.windowHours === h) ? $r('app.color.cc_primary') : $r('app.color.cc_page_bg'))
            .borderRadius(12)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .onClick((): void => {
              // 胶囊着色过渡 + 数值淡入都在同一动画内
              this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
                this.customSelected = false
                this.windowHours = h
              });
              this.playWinFx()
            })
        }, (h: number): string => {
          return String(h)
        })
        Text('自定义')
          .fontSize(14)
          .fontColor(this.customSelected ? $r('app.color.cc_on_primary') : $r('app.color.cc_text_muted'))
          .backgroundColor(this.customSelected ? $r('app.color.cc_primary') : $r('app.color.cc_page_bg'))
          .borderRadius(12)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .onClick((): void => {
            // 自定义行随展开/收合做转场
            this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
              this.customSelected = true
            });
            if (this.customWindowText.length === 0) {
              this.customWindowText = String(this.windowHours)
            }
          })
      }
      .width('100%')

      if (this.customSelected) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '小时 (h)，最大 48', text: this.customWindowText })
            .layoutWeight(1)
            .type(InputType.Number)
            .height(36)
            .borderRadius(8)
            .onChange((v: string): void => {
              this.customWindowText = v
            })
          Button('应用')
            .fontSize(14)
            .scale({ x: this.pressScale('set-window'), y: this.pressScale('set-window') })
            .onTouch((event: TouchEvent): void => {
              this.onBtnTouch('set-window', event);
            })
            .onClick((): void => {
              this.applyCustomWindow()
            })
        }
        .width('100%')
        // 展开/收合：淡入 + 自上方轻微展开
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })))
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  private isCustomWindow(): boolean {
    return this.customSelected;
  }

  private applyCustomWindow(): void {
    const v = Number(this.customWindowText);
    // 过境计算窗口上限就是 48h（PassCache.PASS_CACHE_HOURS），超过 48 填了也不会有数据
    if (Number.isNaN(v) || v <= 0 || v > MAX_WINDOW_HOURS) {
      promptAction.showToast({ message: `请输入 1-${MAX_WINDOW_HOURS} 之间的小时数` });
      return;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
      this.customSelected = false;
      this.windowHours = Math.round(v);
    });
    this.playWinFx();
  }

  @Builder
  private currentSummary() {
    Column({ space: 8 }) {
      Text(`当前生效：${this.savedStationText()}`)
        .fontSize(12)
        .fontColor($r('app.color.cc_text_muted'))
        .width('100%')
        .textAlign(TextAlign.Center)
      Text(`仰角 ≥${AppSettings.getMinElevation()}° · 窗口 ${AppSettings.getWindowHours()}h`)
        .fontSize(12)
        .fontColor($r('app.color.cc_text_muted'))
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
  }

  /** 数据与隐私：清除本机用户数据（合规要求：用户可删除自己的数据）。 */
  @Builder
  private sectionPrivacy() {
    Column({ space: 12 }) {
      Text('数据与隐私')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.cc_text_title'))
        .width('100%')

      Button('清除本机数据')
        .width('100%')
        .height(40)
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor('#E5484D')
        .borderWidth(1)
        .borderColor('#E5484D')
        .scale({ x: this.pressScale('set-clear'), y: this.pressScale('set-clear') })
        .onTouch((event: TouchEvent): void => {
          this.onBtnTouch('set-clear', event);
        })
        .onClick((): void => {
          this.confirmClearLocalData();
        })
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 清除前二次确认，避免误触。 */
  private confirmClearLocalData(): void {
    AlertDialog.show({
      title: '清除本机数据',
      message: '将清除收藏、已选卫星、观测站址、自定义数据源地址与全部录音文件，且不可恢复。确定继续？',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清除',
        fontColor: '#E5484D',
        action: (): void => {
          this.clearLocalData();
        }
      }
    });
  }

  /** 清除本机用户数据：收藏 / 已选卫星 / 站址 / 自定义数据源 / 录音文件。 */
  private clearLocalData(): void {
    Favorites.clear();
    SelectedSats.clear();
    AppSettings.resetStation();
    AppSettings.setCustomTleUrl('');
    AppSettings.setCustomTransponderUrl('');
    this.tleUrlText = '';
    this.transUrlText = '';
    const removed = AudioRecorder.clearRecordings(getContext(this));
    const station = AppSettings.getStation();
    this.latText = station.latitude.toFixed(4);
    this.lonText = station.longitude.toFixed(4);
    this.altText = station.altitude.toFixed(0);
    this.qthText = positionToQth(station.latitude, station.longitude) ?? '';
    promptAction.showToast({ message: removed > 0 ? `已清除本机数据（含 ${removed} 个录音文件）` : '已清除本机数据' });
  }

  @Builder
  private sectionAbout() {
    Text('业余卫星跟踪/过境预报，算法源自 Look4Sat（GPL-3.0）')
      .fontSize(12)
      .fontColor($r('app.color.cc_text_muted'))
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 4 })
  }

  private liveQth(): string {
    const lat = Number(this.latText);
    const lon = Number(this.lonText);
    if (Number.isNaN(lat) || Number.isNaN(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      return '坐标无效';
    }
    return positionToQth(lat, lon) ?? '无法定位';
  }
}