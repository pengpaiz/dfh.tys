/*
 * Look4Sat HarmonyOS. 「追踪」标签页：顶部两段式滑动切换（地图 / 日历）。
 *
 * - 顶部自绘两段控件，高亮胶囊滑动，动画与雷达图详情页统一为 200ms EaseOut
 * - 内容区用 Swiper 承载 MapPage / CalendarPage，支持左右滑动，duration(200) 与雷达图分页一致
 * - 地图页与日历页各自继续负责底部悬浮栏的避让（KEY_BAR_CLEARANCE）
 */

import { MapPage } from './MapPage';
import { CalendarPage } from './CalendarPage';

/** 顶部两段控件的标题 */
const SUB_TITLES: string[] = ['地图', '日历'];
/** AppStorage key：当前激活的子页签（0=地图 / 1=日历），供地图页与日历页判断"是否可见" */
const KEY_TRACK_SUB = 'tracking_sub';
/** 控件高度（vp） */
const SWITCH_H = 38;
/** 控件左右留白（vp） */
const SWITCH_SIDE = 16;
/** 高亮胶囊相对格子的内缩（vp） */
const PILL_INSET = 4;

@Component
export struct TrackingPage {
  @State subIndex: number = 0;
  @State switchW: number = 0;
  private tabsController: SwiperController = new SwiperController();

  /** 单个格子的宽度 */
  private cellW(): number {
    return this.switchW > 0 ? this.switchW / SUB_TITLES.length : 0;
  }

  /** 统一切换入口：三处（点击/滑动）共用同一套动画，保证视觉同步 */
  private applyIndex(index: number, fromSwipe: boolean): void {
    if (index === this.subIndex) {
      return;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
      this.subIndex = index;
    });
    // 通知子页面"谁可见"：地图/日历据此决定是否重算（合并前它们各自用 current_tab 判断）
    AppStorage.setOrCreate<number>(KEY_TRACK_SUB, index);
    if (!fromSwipe) {
      this.tabsController.changeIndex(index);
    }
  }

  aboutToAppear(): void {
    AppStorage.setOrCreate<number>(KEY_TRACK_SUB, this.subIndex);
  }

  build() {
    Column() {
      // ---- 顶部两段式滑动 Tabs ----
      Stack({ alignContent: Alignment.Start }) {
        // 滑动高亮胶囊（位置由 subIndex 驱动，动画见 applyIndex）
        Row()
          .width(this.cellW() > 0 ? Math.max(this.cellW() - PILL_INSET * 2, 0) : 0)
          .height(SWITCH_H - PILL_INSET * 2)
          .backgroundColor($r('app.color.cc_primary'))
          .borderRadius((SWITCH_H - PILL_INSET * 2) / 2)
          .margin({ left: PILL_INSET })
          .translate({ x: this.cellW() * this.subIndex })

        Row() {
          ForEach(SUB_TITLES, (title: string, index: number): void => {
            Text(title)
              .fontSize(14)
              .fontWeight(this.subIndex === index ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.subIndex === index ? $r('app.color.cc_on_primary') : $r('app.color.cc_text_muted'))
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .onClick((): void => {
                this.applyIndex(index, false);
              })
          }, (title: string): string => title)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height(SWITCH_H)
      .padding({ left: SWITCH_SIDE, right: SWITCH_SIDE })
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        const w = Number(newValue.width) - SWITCH_SIDE * 2;
        if (w > 0 && Math.abs(w - this.switchW) > 0.5) {
          this.switchW = w;
        }
      })

      // ---- 内容区：地图 / 日历（与雷达图详情页同一套 Swiper 滑动动画） ----
      Swiper(this.tabsController) {
        MapPage()

        CalendarPage()
      }
      .duration(200)
      .loop(false)
      .indicator(false)
      .layoutWeight(1)
      .width('100%')
      // 动画一开始就同步顶部胶囊，滑动过程中不滞后
      .onAnimationStart((index: number, targetIndex: number): void => {
        this.applyIndex(targetIndex, true);
      })
      .onChange((index: number): void => {
        this.applyIndex(index, true);
      })
    }
    .width('100%')
    .height('100%')
  }
}
