/*
 * Look4Sat HarmonyOS. 「追踪」标签页：顶部两段式滑动 Tabs（地图 / 日历）。
 *
 * - 顶部自绘两段控件，高亮胶囊滑动，动画与底部任务栏同一套 springMotion(0.55, 0.82)
 * - 内容区用 barHeight(0) 的 Tabs 承载 MapPage / CalendarPage：
 *   左右滑动切页，与顶部胶囊双向同步（点击 ↔ 滑动）
 * - 地图页与日历页各自继续负责底部悬浮栏的避让（KEY_BAR_CLEARANCE）
 */

import { curves } from '@kit.ArkUI';
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
  private tabsController: TabsController = new TabsController();

  /** 单个格子的宽度 */
  private cellW(): number {
    return this.switchW > 0 ? this.switchW / SUB_TITLES.length : 0;
  }

  /** 统一切换入口：三处（点击/滑动）共用同一套动画，保证视觉同步 */
  private applyIndex(index: number, fromSwipe: boolean): void {
    if (index === this.subIndex) {
      return;
    }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.55, 0.82) }, (): void => {
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

  /** 内容区用不到系统栏，给一个 0 高度的占位 tabBar 保证 TabContent 合法 */
  @Builder
  private emptyTabBar() {
    Column().width('100%').height('100%')
  }

  build() {
    Column() {
      // ---- 顶部两段式滑动 Tabs ----
      Stack({ alignContent: Alignment.Start }) {
        // 滑动高亮胶囊（位置由 subIndex 驱动，动画见 applyIndex）
        Row()
          .width(this.cellW() > 0 ? Math.max(this.cellW() - PILL_INSET * 2, 0) : 0)
          .height(SWITCH_H - PILL_INSET * 2)
          .backgroundColor($r('app.color.cc_card'))
          .borderRadius((SWITCH_H - PILL_INSET * 2) / 2)
          .margin({ left: PILL_INSET })
          .translate({ x: this.cellW() * this.subIndex })

        Row() {
          ForEach(SUB_TITLES, (title: string, index: number): void => {
            Text(title)
              .fontSize(14)
              .fontWeight(this.subIndex === index ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.subIndex === index ? $r('app.color.cc_text_title') : $r('app.color.cc_text_muted'))
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

      // ---- 内容区：地图 / 日历 ----
      Tabs({ barPosition: BarPosition.End, index: this.subIndex, controller: this.tabsController }) {
        TabContent() {
          MapPage()
        }
        .tabBar(this.emptyTabBar())

        TabContent() {
          CalendarPage()
        }
        .tabBar(this.emptyTabBar())
      }
      .barHeight(0)
      // 禁用左右滑动切子页（地图/日历）：只允许点顶部分段控件切换
      .scrollable(false)
      .layoutWeight(1)
      .width('100%')
      .onChange((index: number): void => {
        this.applyIndex(index, true);
      })
    }
    .width('100%')
    .height('100%')
  }
}
