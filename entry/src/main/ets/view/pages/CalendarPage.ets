/*
 * Look4Sat. Calendar page: per-day count of satellites passing over the
 * station within the next 14 days, based on the selected satellites.
 */

import { SatelliteApp } from '../../common/SatelliteApp';
import { SelectedSats } from '../../common/SelectedSats';
import { AppSettings } from '../../common/AppSettings';
import { SAT_COLORS } from '../../common/SatColors';
import { SatOrbitalData } from '../../domain/predict/OrbitalData';
import { SatPassEvent } from '../../domain/predict/SatPassFinder';
import { CalendarForecast } from '../../domain/predict/CalendarForecast';
import { KEY_BAR_CLEARANCE, TAB_BAR_CLEARANCE } from '../../common/LayoutMetrics';
import { ENTER_SCALE, PRESS_IN_MS, PRESS_OUT_MS, PRESS_SCALE } from '../components/PressFx';

/** 日历视图状态：加载中 / 就绪 / 确实为空 */
enum CalViewState {
  LOADING = 0,
  READY = 1,
  EMPTY = 2
}

/** 本页所在的底部标签：日历已并入「追踪」页（顶部子页签），故与地图同属标签 1 */
const TAB_CALENDAR = 1;
/** 切到日历页后延后多久开始重算（让入场动画先跑完，避免抢主线程） */
const CALC_START_DELAY_MS = 360;
/** 每算完一颗星让出多久：给渲染一帧的时间，保证滚动/动画不卡 */
const CALC_YIELD_MS = 16;
const FORECAST_DAYS = 14;
const MAX_CALC_SATS = 20;
const DAY_MS = 86400000;
const WEEK_LABELS: string[] = ['日', '一', '二', '三', '四', '五', '六'];

class DayStat {
  passCount: number = 0;
  satCats: number[] = [];
}

class CalCell {
  day: number;
  dateMillis: number;
  inMonth: boolean;
  isToday: boolean;
  inRange: boolean;
  satCount: number;
  passCount: number;

  constructor(day: number, dateMillis: number, inMonth: boolean, isToday: boolean,
              inRange: boolean, satCount: number, passCount: number) {
    this.day = day;
    this.dateMillis = dateMillis;
    this.inMonth = inMonth;
    this.isToday = isToday;
    this.inRange = inRange;
    this.satCount = satCount;
    this.passCount = passCount;
  }
}

class CalPass {
  catnum: number;
  name: string;
  color: string;
  pass: SatPassEvent;

  constructor(catnum: number, name: string, color: string, pass: SatPassEvent) {
    this.catnum = catnum;
    this.name = name;
    this.color = color;
    this.pass = pass;
  }
}

@Component
export struct CalendarPage {
  @State year: number = 2026;
  @State month: number = 0;
  @State weeks: CalCell[][] = [];
  @State dayList: CalPass[] = [];
  @State daySatCount: number = 0;
  @State dayPassCount: number = 0;
  @State computing: boolean = false;
  @State selectedMillis: number = 0;
  @StorageLink('selected_version') @Watch('recompute') selVersion: number = 0;
  @StorageLink('data_version') @Watch('recompute') dataVersion: number = 0;
  @StorageLink('settings_min_elevation') @Watch('recompute') minElevation: number = 5;
  @StorageLink('station_latitude') @Watch('recompute') stationLat: number = 48.2;
  @StorageLink('station_longitude') @Watch('recompute') stationLon: number = 16.37;
  @StorageLink('station_altitude') @Watch('recompute') stationAlt: number = 0;
  @StorageProp('current_tab') @Watch('onTabChanged') currentTab: number = TAB_CALENDAR;
  /** 当前激活的子页签（0=地图 / 1=日历）：日历并入「追踪」后靠它判断自身是否真的可见 */
  @StorageProp('tracking_sub') @Watch('onTrackSubChanged') trackSub: number = 1;

  private dirty: boolean = false;
  @State pressedBtn: string = '';
  @State btnEntered: boolean = false;
  private app: SatelliteApp = SatelliteApp.getInstance();
  private stats: Map<number, DayStat> = new Map();
  private passesByDay: Map<number, CalPass[]> = new Map();
  private computeSeq: number = 0;
  private gridVersion: number = 0;
  /** 已排程的计算定时器 id（-1 表示没有待执行的计算） */
  private pendingCalcId: number = -1;
  /** 切换月份动画：进度 0→1，方向 -1 上一月 / +1 下一月 */
  @State gridFx: number = 1;
  @State gridDir: number = 1;
  /** 日历视图状态：加载中 / 就绪 / 确实为空 */
  @State calState: CalViewState = CalViewState.LOADING;
  /** 是否已完成一轮计算（用于区分"还没算完"和"确实没有"） */
  private calcFinished: boolean = false;
  /** 底部预留（由 Index 按栏高+导航条避让算出后发布） */
  @StorageProp(KEY_BAR_CLEARANCE) barClearance: number = TAB_BAR_CLEARANCE;

  aboutToAppear(): void {
    const now = new Date();
    this.year = now.getFullYear();
    this.month = now.getMonth();
    this.selectedMillis = this.dayStart(now.getTime());
    this.dirty = false;
    const cats = SelectedSats.getCats();
    const all = this.app.getStore().getAll();
    if (cats.length === 0 || all.length === 0) {
      // 没有任何待计算内容：直接按"空"处理，不算加载中
      this.calState = this.app.hasStoreLoaded() ? CalViewState.EMPTY : CalViewState.LOADING;
      this.rebuildCells();
      this.applyDaySelection();
      return;
    }
    // 已有缓存（启动时 Index 已后台预热过）：立即汇总出结果，不显示"无数据"也不等待
    const forecast = CalendarForecast.getInstance();
    forecast.prepare(this.dataVersion);
    if (forecast.hasAll(cats.slice(0, MAX_CALC_SATS))) {
      const seq = ++this.computeSeq;
      this.runCompute(seq);
      return;
    }
    // 缓存不齐：保持加载态，延后开算（先让入场动画跑完）
    this.calState = CalViewState.LOADING;
    this.scheduleCompute();
  }

  /** 本页是否真的可见：既要在「追踪」标签上，子页签也必须是「日历」。 */
  private isVisible(): boolean {
    return this.currentTab === TAB_CALENDAR && this.trackSub === 1;
  }

  /** 本页不可见时只记脏标记：14 天预报很贵，切到日历页再算。 */
  recompute(): void {
    if (!this.isVisible()) {
      this.dirty = true;
      return;
    }
    this.dirty = false;
    const cats = SelectedSats.getCats();
    const forecast = CalendarForecast.getInstance();
    forecast.prepare(this.dataVersion);
    if (forecast.hasAll(cats.slice(0, MAX_CALC_SATS))) {
      // 缓存已热：直接汇总（毫秒级），不走"加载中"
      const seq = ++this.computeSeq;
      this.runCompute(seq);
      return;
    }
    this.calState = CalViewState.LOADING;
    this.scheduleCompute();
  }

  onTabChanged(): void {
    if (this.isVisible()) {
      if (this.dirty) {
        this.dirty = false;
        this.scheduleCompute();
      }
    } else if (this.pendingCalcId >= 0) {
      // 还没开算就切走了：取消，避免在不可见时白算
      clearTimeout(this.pendingCalcId);
      this.pendingCalcId = -1;
      this.dirty = true;
    }
  }

  /** 在「追踪」内切换子页签：切到日历且有待算内容时立即重算，避免显示上一次的旧数据。 */
  onTrackSubChanged(): void {
    if (this.isVisible()) {
      this.dirty = false;
      this.recompute();
    }
  }

  /**
   * 延后一点再开算：切到日历页时先让入场动画跑完，避免重算和动画抢主线程导致卡顿。
   * 已排程时不再重复排（到点后 runCompute 会重新读取最新状态）。
   */
  private scheduleCompute(): void {
    if (this.pendingCalcId >= 0) {
      return;
    }
    this.pendingCalcId = setTimeout((): void => {
      this.pendingCalcId = -1;
      if (!this.isVisible()) {
        this.dirty = true;
        return;
      }
      const seq = ++this.computeSeq;
      this.runCompute(seq);
    }, CALC_START_DELAY_MS);
  }

  private async runCompute(seq: number): Promise<void> {
    const cats = SelectedSats.getCats();
    const all = this.app.getStore().getAll();
    const station = AppSettings.getStation();
    const minElev = this.minElevation;
    const now = Date.now();
    const forecast = CalendarForecast.getInstance();
    if (cats.length === 0 || all.length === 0) {
      forecast.prepare(this.dataVersion);
      this.computing = false;
      this.calcFinished = true;
      this.stats = new Map();
      this.passesByDay = new Map();
      this.rebuildCells();
      this.applyDaySelection();
      this.calState = this.app.hasStoreLoaded() ? CalViewState.EMPTY : CalViewState.LOADING;
      return;
    }
    // 共享缓存：启动/选星时已由后台预热过，这里通常直接命中；没命中的才补算
    forecast.prepare(this.dataVersion);
    const used = cats.slice(0, MAX_CALC_SATS);
    const missing: number[] = [];
    for (let i = 0; i < used.length; i++) {
      if (!forecast.has(used[i])) {
        missing.push(used[i]);
      }
    }
    this.computing = missing.length > 0;
    this.calcFinished = false;
    // 先用手上的缓存出图，再逐颗补算
    this.aggregate(used, minElev);
    for (let i = 0; i < missing.length; i++) {
      const catnum = missing[i];
      const satData = this.findSat(all, catnum);
      if (satData === null) {
        continue;
      }
      forecast.computeOne(catnum, satData, station, now);
      await this.yieldFrame();
      if (seq !== this.computeSeq) {
        return;
      }
      this.aggregate(used, minElev);
    }
    this.computing = false;
    this.calcFinished = true;
    this.aggregate(used, minElev);
  }

  /** 把缓存里已选星的过境按当前仰角门槛汇总成每日统计与当日明细。 */
  private aggregate(used: number[], minElev: number): void {
    const forecast = CalendarForecast.getInstance();
    const stats = new Map<number, DayStat>();
    const byDay = new Map<number, CalPass[]>();
    for (let i = 0; i < used.length; i++) {
      if (!forecast.has(used[i])) {
        continue;
      }
      const passes = forecast.passesOf(used[i]);
      const name = forecast.nameOf(used[i]);
      const color = SAT_COLORS[i % SAT_COLORS.length];
      for (let j = 0; j < passes.length; j++) {
        const p = passes[j];
        if (p.maxElevationDeg < minElev) {
          continue;
        }
        const key = this.dayStart(p.aosTime);
        let stat = stats.get(key);
        if (stat === undefined) {
          stat = new DayStat();
          stats.set(key, stat);
        }
        stat.passCount++;
        if (stat.satCats.indexOf(used[i]) < 0) {
          stat.satCats.push(used[i]);
        }
        let list = byDay.get(key);
        if (list === undefined) {
          list = [];
          byDay.set(key, list);
        }
        list.push(new CalPass(used[i], name, color, p));
      }
    }
    this.stats = stats;
    this.passesByDay = byDay;
    this.rebuildCells();
    this.applyDaySelection();
    // 状态判定：只要汇总到任何一颗星的缓存就算"就绪"；全算完仍无缓存才是"确实为空"
    let anyCached = false;
    for (let i = 0; i < used.length; i++) {
      if (forecast.has(used[i])) {
        anyCached = true;
        break;
      }
    }
    if (anyCached) {
      this.calState = CalViewState.READY;
    } else if (this.calcFinished) {
      this.calState = this.app.hasStoreLoaded() ? CalViewState.EMPTY : CalViewState.LOADING;
    } else {
      this.calState = CalViewState.LOADING;
    }
  }

  private yieldFrame(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, CALC_YIELD_MS);
    });
  }

  private dayStart(millis: number): number {
    const d = new Date(millis);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  }

  private todayStart(): number {
    return this.dayStart(Date.now());
  }

  private inForecast(dateMillis: number): boolean {
    const diff = Math.round((dateMillis - this.todayStart()) / DAY_MS);
    return diff >= 0 && diff < FORECAST_DAYS;
  }

  private rebuildCells(): void {
    this.gridVersion++;
    const cells: CalCell[][] = [];
    const first = new Date(this.year, this.month, 1);
    const offset = first.getDay();
    const todayStart = this.todayStart();
    const gridStart = this.dayStart(new Date(this.year, this.month, 1 - offset).getTime());
    for (let w = 0; w < 6; w++) {
      const week: CalCell[] = [];
      for (let d = 0; d < 7; d++) {
        const dateMillis = this.dayStart(gridStart + (w * 7 + d) * DAY_MS);
        const cd = new Date(dateMillis);
        const inMonth = cd.getMonth() === this.month && cd.getFullYear() === this.year;
        const isToday = dateMillis === todayStart;
        const inRange = this.inForecast(dateMillis);
        let satCount = 0;
        let passCount = 0;
        const stat = this.stats.get(dateMillis);
        if (stat !== undefined) {
          satCount = stat.satCats.length;
          passCount = stat.passCount;
        }
        week.push(new CalCell(cd.getDate(), dateMillis, inMonth, isToday, inRange, satCount, passCount));
      }
      cells.push(week);
    }
    this.weeks = cells;
  }

  private prevMonth(): void {
    let y = this.year;
    let m = this.month - 1;
    if (m < 0) {
      m = 11;
      y--;
    }
    this.year = y;
    this.month = m;
    this.fixSelectionForMonth();
    this.rebuildCells();
    this.applyDaySelection();
    this.gridDir = -1;
    this.playGridFx();
  }

  private nextMonth(): void {
    let y = this.year;
    let m = this.month + 1;
    if (m > 11) {
      m = 0;
      y++;
    }
    this.year = y;
    this.month = m;
    this.fixSelectionForMonth();
    this.rebuildCells();
    this.applyDaySelection();
    this.gridDir = 1;
    this.playGridFx();
  }

  private canPrev(): boolean {
    const t = new Date();
    return this.year > t.getFullYear() || (this.year === t.getFullYear() && this.month > t.getMonth());
  }

  private canNext(): boolean {
    const end = new Date(this.todayStart() + (FORECAST_DAYS - 1) * DAY_MS);
    return this.year < end.getFullYear() || (this.year === end.getFullYear() && this.month < end.getMonth());
  }

  private fixSelectionForMonth(): void {
    const sel = new Date(this.selectedMillis);
    if (sel.getFullYear() === this.year && sel.getMonth() === this.month) {
      return;
    }
    const daysInMonth = new Date(this.year, this.month + 1, 0).getDate();
    let pick = -1;
    for (let d = 1; d <= daysInMonth; d++) {
      const m = new Date(this.year, this.month, d).getTime();
      if (this.inForecast(m)) {
        pick = m;
        break;
      }
    }
    if (pick < 0) {
      pick = new Date(this.year, this.month, 1).getTime();
    }
    this.selectedMillis = pick;
  }

  private selectDay(cell: CalCell): void {
    if (!cell.inMonth) {
      const d = new Date(cell.dateMillis);
      const targetY = d.getFullYear();
      const targetM = d.getMonth();
      // 点击上/下月的补位日期会跳月：按目标月相对当前月的方向播切换动画
      const after = targetY > this.year || (targetY === this.year && targetM > this.month);
      this.gridDir = after ? 1 : -1;
      this.year = targetY;
      this.month = targetM;
      this.selectedMillis = cell.dateMillis;
      this.rebuildCells();
      this.applyDaySelection();
      this.playGridFx();
      return;
    }
    this.selectedMillis = cell.dateMillis;
    this.gridVersion++;
    this.applyDaySelection();
  }

  private applyDaySelection(): void {
    let list = this.passesByDay.get(this.selectedMillis);
    if (list === undefined) {
      list = [];
    }
    const sorted = Array.from(list);
    sorted.sort((a: CalPass, b: CalPass): number => b.pass.maxElevationDeg - a.pass.maxElevationDeg);
    this.dayList = sorted;
    const satCats: number[] = [];
    for (let i = 0; i < sorted.length; i++) {
      if (satCats.indexOf(sorted[i].catnum) < 0) {
        satCats.push(sorted[i].catnum);
      }
    }
    this.daySatCount = satCats.length;
    this.dayPassCount = sorted.length;
  }

  private findSat(all: SatOrbitalData[], catnum: number): SatOrbitalData | null {
    for (let i = 0; i < all.length; i++) {
      if (all[i].catnum === catnum) {
        return all[i];
      }
    }
    return null;
  }

  private isSelected(cell: CalCell): boolean {
    return cell.dateMillis === this.selectedMillis && cell.inMonth;
  }

  private hasSelection(): boolean {
    return SelectedSats.getCats().length > 0;
  }

  private hasData(): boolean {
    return this.app.getStore().getAll().length > 0;
  }

  private monthTitle(): string {
    return `${this.year}年${this.month + 1}月`;
  }

  private rangeTitle(): string {
    return `未来${FORECAST_DAYS}天 · 仰角≥${this.minElevation}°`;
  }

  private dayTitle(): string {
    const d = new Date(this.selectedMillis);
    const wd = WEEK_LABELS[d.getDay()];
    const rel = this.selectedMillis === this.todayStart() ? '今天 · ' : '';
    return `${rel}${d.getMonth() + 1}月${d.getDate()}日 · 周${wd}`;
  }

  private daySummary(): string {
    if (!this.inForecast(this.selectedMillis)) {
      return `超出${FORECAST_DAYS}天预报范围`;
    }
    return `${this.daySatCount} 颗卫星 · ${this.dayPassCount} 次过境`;
  }

  private clock(millis: number): string {
    const d = new Date(millis);
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }

  // ---- 按钮动画 ----

  /**
   * 切换月份动画：与卫星页选择动画同一套（320ms + Friction）。
   * 先瞬回 0（duration=0 不产生动画），下一帧再动画到 1。
   */
  private playGridFx(): void {
    this.getUIContext().animateTo({ duration: 0, curve: Curve.Linear }, (): void => {
      this.gridFx = 0;
    });
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
        this.gridFx = 1;
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
    Column() {
      this.headerBar()
      this.weekHeader()
      this.gridArea()
      Divider()
        .color('#2A3B52')
        .margin({ top: 4, bottom: 4 })
      this.dayDetail()
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
  private headerBar() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Button('‹')
          .type(ButtonType.Circle)
          .width(32)
          .height(32)
          .fontSize(14)
          .fontColor($r('app.color.cc_on_primary'))
          .backgroundColor($r('app.color.cc_primary'))
          .enabled(this.canPrev())
          .opacity(this.canPrev() ? 1 : 0.35)
          .scale({ x: this.pressScale('cal-prev'), y: this.pressScale('cal-prev') })
          .onTouch((event: TouchEvent): void => {
            this.onBtnTouch('cal-prev', event);
          })
          .onClick((): void => {
            this.prevMonth()
          })
        Text(this.monthTitle())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.cc_text_title'))
          .layoutWeight(1)
          // 月份标题与网格同步按方向滑入淡入
          .opacity(0.15 + 0.85 * this.gridFx)
          .translate({ x: 10 * this.gridDir * (1 - this.gridFx) })
          .textAlign(TextAlign.Center)
        Button('›')
          .type(ButtonType.Circle)
          .width(32)
          .height(32)
          .fontSize(14)
          .fontColor($r('app.color.cc_on_primary'))
          .backgroundColor($r('app.color.cc_primary'))
          .enabled(this.canNext())
          .opacity(this.canNext() ? 1 : 0.35)
          .scale({ x: this.pressScale('cal-next'), y: this.pressScale('cal-next') })
          .onTouch((event: TouchEvent): void => {
            this.onBtnTouch('cal-next', event);
          })
          .onClick((): void => {
            this.nextMonth()
          })
      }
      .width('100%')

      Row({ space: 6 }) {
        Text(this.rangeTitle())
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
        if (this.computing) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color($r('app.color.cc_primary'))
          Text('计算中…')
            .fontSize(12)
            .fontColor($r('app.color.cc_text_muted'))
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 4 })
  }

  @Builder
  private weekHeader() {
    Row() {
      ForEach(WEEK_LABELS, (label: string) => {
        Text(label)
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }, (label: string): string => label)
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
  }

  @Builder
  private gridArea() {
    Column() {
      ForEach(this.weeks, (week: CalCell[]) => {
        Row() {
          ForEach(week, (cell: CalCell) => {
            Column() {
              Text(String(cell.day))
                .fontSize(14)
                .fontWeight(cell.isToday || this.isSelected(cell) ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.cellTextColor(cell))
                .textAlign(TextAlign.Center)
                .width(30)
                .height(30)
                .borderRadius(12)
                .backgroundColor(cell.isToday ? '#40FFFFFF' : Color.Transparent)
            }
            .layoutWeight(1)
            .height(46)
            .justifyContent(FlexAlign.Center)
            .borderRadius(8)
            .backgroundColor(this.isSelected(cell) ? $r('app.color.cc_card') : Color.Transparent)
            .onClick((): void => {
              this.selectDay(cell)
            })
          }, (cell: CalCell): string => `${this.gridVersion}-${cell.dateMillis}`)
        }
        .width('100%')
      }, (week: CalCell[]): string => `${this.year}-${this.month}-${this.gridVersion}-${week[0].dateMillis}`)
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
    // 切换月份：整月网格按方向滑入 + 淡入（320ms Friction）
    .opacity(0.15 + 0.85 * this.gridFx)
    .translate({ x: 14 * this.gridDir * (1 - this.gridFx) })
  }

  private cellTextColor(cell: CalCell): ResourceColor {
    if (this.isSelected(cell)) {
      return $r('app.color.cc_primary');
    }
    if (cell.isToday) {
      return $r('app.color.cc_primary');
    }
    if (!cell.inMonth) {
      return '#5A6B80';
    }
    return $r('app.color.cc_text_title');
  }

  @Builder
  private dayDetail() {
    Column({ space: 8 }) {
      Row() {
        Text(this.dayTitle())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.cc_text_title'))
        Blank()
        Text(this.daySummary())
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
      }
      .width('100%')

      if (!this.hasData()) {
        Text('卫星数据加载中…')
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
          .width('100%')
          .padding({ top: 20, bottom: 20 })
          .textAlign(TextAlign.Center)
      } else if (!this.hasSelection()) {
        Text('请在“卫星”标签页选择要跟踪的卫星')
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
          .width('100%')
          .padding({ top: 20, bottom: 20 })
          .textAlign(TextAlign.Center)
      } else if (this.dayList.length === 0) {
        // 加载中（含"还没开始算"）显示"正在计算"，避免误报"当日暂无达标过境"
        Text(this.calState === CalViewState.LOADING
          ? '正在计算…'
          : (this.inForecast(this.selectedMillis) ? '当日暂无达标过境' : '该日期超出预报范围'))
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
          .width('100%')
          .padding({ top: 20, bottom: 20 })
          .textAlign(TextAlign.Center)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.dayList, (cp: CalPass) => {
              Row({ space: 10 }) {
                Circle({ width: 8, height: 8 }).fill(cp.color)
                Column({ space: 2 }) {
                  Text(cp.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(cp.color)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`NORAD ${cp.catnum}`)
                    .fontSize(12)
                    .fontColor($r('app.color.cc_text_muted'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text(`${this.clock(cp.pass.aosTime)} - ${this.clock(cp.pass.losTime)}`)
                  .fontSize(12)
                  .fontColor($r('app.color.cc_text_title'))
                Text(`最高 ${cp.pass.maxElevationDeg.toFixed(0)}°`)
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(cp.color)
              }
              .width('100%')
              .padding(10)
              .backgroundColor($r('app.color.cc_card'))
              .borderRadius(8)
            }, (cp: CalPass): string => `${cp.catnum}-${cp.pass.aosTime}`)
          }
          .width('100%')
          // 预留右侧滚动条宽度 + 底部给胶囊栏留空间（加在滚动内容上，页面可视区仍铺到底）
          .padding({ right: 8, bottom: this.barClearance })
        }
        .layoutWeight(1)
        .width('100%')
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
      }
    }
    .layoutWeight(1)
    .width('100%')
    // 不再给这里加底部 padding：padding 会缩小可视区导致底部空一条，改为放在 Scroll 内容里
    .padding({ left: 14, right: 14, top: 4, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }
}
