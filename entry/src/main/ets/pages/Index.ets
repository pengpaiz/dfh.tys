import { SatelliteListPage } from '../view/pages/SatelliteListPage';
import { PassesPage } from '../view/pages/PassesPage';
import { TrackingPage } from '../view/pages/TrackingPage';
import { DecodePage } from '../view/pages/DecodePage';
import { SettingsPage } from '../view/pages/SettingsPage';
import { SatelliteApp } from '../common/SatelliteApp';
import { SelectedSats } from '../common/SelectedSats';
import { Favorites } from '../common/Favorites';
import { AppSettings } from '../common/AppSettings';
import { CalendarForecast } from '../domain/predict/CalendarForecast';
import { GlassTabBar, GlassTabItem } from '../view/components/GlassTabBar';
import { curves, window } from '@kit.ArkUI';

/** 默认停留标签（2 = 过境） */
const DEFAULT_TAB = 2;
/** 页面入场：起始不透明度与上浮距离 */
const PAGE_FX_MIN_OPACITY = 0.4;
const PAGE_FX_OFFSET = 14;

/**
 * 应用外壳：承载 5 个页面（Tabs，barHeight=0）+ 独立悬浮任务栏（GlassTabBar）。
 *
 * 职责边界：
 * - 本组件只负责「页面承载 + 页面切换的副作用（切换页签、页面入场动画、当前页广播）」；
 * - 悬浮栏的绘制、手势、几何与底部预留，全部下沉到 GlassTabBar（view/components/GlassTabBar.ets）。
 *
 * 页面入场动画：springMotion(0.32, 0.62) 驱动淡入 + 上浮，与胶囊同一套弹簧语言。
 */
@Entry
@Component
struct Index {
  // ---- 状态 ----
  @State selectedIndex: number = DEFAULT_TAB;
  /** 顶部状态栏避让高度：窗口铺满整屏后由页面自己让出 */
  @State statusInset: number = 0;
  /** 页面入场进度 0→1（淡入 + 上浮） */
  @State pageFx: number = 1;
  /** 日历 14 天预报的预热输入：任一变化就后台预计算，保证切到日历页即可用 */
  @StorageProp('selected_version') @Watch('onForecastInputsChanged') selectedVersion: number = 0;
  @StorageProp('data_version') @Watch('onForecastInputsChanged') dataVersion: number = 0;
  @StorageProp('station_version') @Watch('onForecastInputsChanged') stationVersion: number = 0;

  private tabsController: TabsController = new TabsController();
  private app: SatelliteApp = SatelliteApp.getInstance();
  private items: GlassTabItem[] = [
    new GlassTabItem('卫星', $r('sys.symbol.satellite')),
    new GlassTabItem('追踪', $r('sys.symbol.scope')),
    new GlassTabItem('过境', $r('sys.symbol.dot_radiowaves_left_and_right')),
    new GlassTabItem('解码', $r('app.media.tab_decode'), true),
    new GlassTabItem('设置', $r('sys.symbol.gearshape'))
  ];

  aboutToAppear(): void {
    // 首个可见标签：各地图/过境/日历页据此判断是否值得立刻重算
    AppStorage.setOrCreate<number>('current_tab', this.selectedIndex);
    AppSettings.init();
    this.app.init(getContext(this));
    SelectedSats.init();
    Favorites.init();
    // 读取状态栏避让高度：窗口已铺满整屏，安全区由页面自己让出
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      const status = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusInset = this.getUIContext().px2vp(status.topRect.height);
    });
    // 只加载本地数据（本机文件，不含个人信息），缺数据时用内置快照离线播种；
    // 不联网、不定位——位置权限只在用户主动点「定位到当前位置」时申请
    this.app.loadFromDisk().then((): void => {
      // 本地数据就绪后立刻预热日历预报（后台逐颗算，不阻塞交互）
      this.warmCalendarForecast();
      this.app.startupOfflineSeed();
    });
    // 读取内置离线数据（打包快照）的版本时间，供设置页标明
    this.app.loadSnapshotInfo();
  }

  /** 选择集 / 数据 / 站址变化时后台补算日历预报，使日历与过境页随时一致。 */
  onForecastInputsChanged(): void {
    this.warmCalendarForecast();
  }

  private warmCalendarForecast(): void {
    CalendarForecast.getInstance().warmup(SelectedSats.getCats(), this.dataVersion);
  }

  /**
   * 立即归零（duration=0，不产生动画）：让新页以淡态入场。
   * 必须在切页「之前」调用，否则新页会先以完整态显示一帧，再变淡 → 看起来"闪/瞪"一下。
   */
  private primeEnterFx(): void {
    this.getUIContext().animateTo({ duration: 0, curve: Curve.Linear }, (): void => {
      this.pageFx = 0;
    });
  }

  /** 下一帧淡入 + 上浮到 1（与任务栏胶囊同一套弹簧曲线） */
  private runEnterFx(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.62) }, (): void => {
        this.pageFx = 1;
      });
    }, 0);
  }

  /**
   * 统一切页入口：先 prime（归零）→ 更新索引/广播 → 切 Tabs → run（淡入）。
   * 点击/拖动（GlassTabBar.onTabChange）与横滑（Tabs.onChange）都走这里，
   * 保证任意路径下新页都从淡态开始，消除切换瞬间的闪跳。
   */
  private switchTo(index: number): void {
    if (index === this.selectedIndex) {
      return;
    }
    this.primeEnterFx();
    this.selectedIndex = index;
    AppStorage.setOrCreate<number>('current_tab', index);
    this.tabsController.changeIndex(index);
    this.runEnterFx();
  }

  /** 系统 tabBar 置空（栏高为 0，仅占位以保证 TabContent 合法） */
  @Builder
  emptyTabBar() {
    Column().width('100%').height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // === 内容层：barHeight(0) → 页面铺满整屏，栏的位置完全由下方浮栏决定 ===
      Tabs({ barPosition: BarPosition.End, index: this.selectedIndex, controller: this.tabsController }) {
        TabContent() {
          Column() {
            SatelliteListPage()
          }
          .width('100%')
          .height('100%')
          .opacity(PAGE_FX_MIN_OPACITY + (1 - PAGE_FX_MIN_OPACITY) * this.pageFx)
          .translate({ y: PAGE_FX_OFFSET * (1 - this.pageFx) })
        }
        .tabBar(this.emptyTabBar())

        TabContent() {
          Column() {
            TrackingPage()
          }
          .width('100%')
          .height('100%')
          .opacity(PAGE_FX_MIN_OPACITY + (1 - PAGE_FX_MIN_OPACITY) * this.pageFx)
          .translate({ y: PAGE_FX_OFFSET * (1 - this.pageFx) })
        }
        .tabBar(this.emptyTabBar())

        TabContent() {
          Column() {
            PassesPage()
          }
          .width('100%')
          .height('100%')
          .opacity(PAGE_FX_MIN_OPACITY + (1 - PAGE_FX_MIN_OPACITY) * this.pageFx)
          .translate({ y: PAGE_FX_OFFSET * (1 - this.pageFx) })
        }
        .tabBar(this.emptyTabBar())

        TabContent() {
          Column() {
            DecodePage()
          }
          .width('100%')
          .height('100%')
          .opacity(PAGE_FX_MIN_OPACITY + (1 - PAGE_FX_MIN_OPACITY) * this.pageFx)
          .translate({ y: PAGE_FX_OFFSET * (1 - this.pageFx) })
        }
        .tabBar(this.emptyTabBar())

        TabContent() {
          Column() {
            SettingsPage()
          }
          .width('100%')
          .height('100%')
          .opacity(PAGE_FX_MIN_OPACITY + (1 - PAGE_FX_MIN_OPACITY) * this.pageFx)
          .translate({ y: PAGE_FX_OFFSET * (1 - this.pageFx) })
        }
        .tabBar(this.emptyTabBar())
      }
      .barMode(BarMode.Fixed)
      .vertical(false)
      // 禁用左右滑动切页：只允许点任务栏切换
      .scrollable(false)
      .barHeight(0)
      .backgroundColor($r('app.color.cc_page_bg'))
      // 窗口铺满整屏后，顶部状态栏的避让由这里让出（页面内容不会被状态栏压住）
      .padding({ top: this.statusInset })
      .onChange((index: number): void => {
        // 横滑切换（以及 changeIndex 的回环）统一走 switchTo；重复索引会被内部忽略
        this.switchTo(index);
      })
      .width('100%')
      .height('100%')

      // === 独立悬浮任务栏：绘制 + 手势 + 几何全部内聚在组件内 ===
      GlassTabBar({
        selectedIndex: this.selectedIndex,
        items: this.items,
        onTabChange: (index: number): void => {
          // 点击/拖动命中新页签：先归零再切页，消除"完整显示一帧再闪"
          this.switchTo(index);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.cc_page_bg'))
    // 窗口已铺满整屏：两个方向都由本应用绘制，这样底部不会再露出窗口背景（深色下=黑条）。
    // 顶部状态栏的避让改由下方 Tabs 的内边距让出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}