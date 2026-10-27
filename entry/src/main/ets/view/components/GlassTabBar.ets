import { curves, window } from '@kit.ArkUI';
import { KEY_BAR_CLEARANCE } from '../../common/LayoutMetrics';

/** 中间突出显示的页签（过境） */
const CENTER_INDEX = 2;
/** 中间「过境」按钮的强调色 */
const CENTER_ACCENT = '#FFD54F';
/** 任务栏胶囊底：毛玻璃 + 一层很淡的白，避免深色主题下显得是黑底 */
const BAR_CAPSULE_TINT = '#1FFFFFFF';
/** 悬浮栏几何兜底值（vp）；真实值由窗口高度推算，见 barHeightVp()/barBottomVp() */
const BAR_HEIGHT_BASE = 70;
const BAR_BOTTOM_BASE = 2;
/** 悬浮栏左右边距（vp） */
const BAR_SIDE_MARGIN = 16;
/** 图标行相对胶囊底的内缩：保证最左/最右页签的高亮胶囊完整落在胶囊底内（不被圆角切掉） */
const BAR_CELL_INSET = 18;
/** 高亮胶囊宽度 = 格宽 × 该比例；胶囊高度 = 栏高 - 该值 */
const PILL_WIDTH_RATIO = 0.78;
const PILL_HEIGHT_INSET = 6;
/** 静止时胶囊的"略大"尺寸 */
const REST_SCALE = 1.12;

/** 底栏页签数据模型 */
export class GlassTabItem {
  title: string;
  icon: Resource;
  /** 是否为自绘像素 SVG 图标：true 用 Image 渲染；false（系统符号）用 SymbolGlyph 渲染 */
  pixel: boolean;

  constructor(title: string, icon: Resource, pixel: boolean = false) {
    this.title = title;
    this.icon = icon;
    this.pixel = pixel;
  }
}

/**
 * 底部悬浮玻璃任务栏（独立组件）
 *
 * 与页面切换解耦：本组件只负责「悬浮栏的绘制 + 手势/点击交互 + 几何计算」，
 * 不持有 Tabs 控制器；页签切换通过 [onTabChange] 回调交给宿主页面执行，
 * 宿主再把最新索引回传给 [selectedIndex]，由 @Watch 驱动胶囊归位。
 *
 * 动画语言：
 * - 胶囊跟手拖动，按累计距离放大、按速度变扁、按纵向偏移形变，松手吸附并 Q 弹回
 * - 图标按与胶囊的距离 smoothstep 缩放/抬起/变色
 */
@Component
export struct GlassTabBar {
  /** 当前页签（由宿主驱动；内部点击/拖动通过 onTabChange 回传后由宿主更新） */
  @Prop @Watch('onIndexChanged') selectedIndex: number = 0;
  /** 页签数据（标题 + Symbol 图标） */
  items: GlassTabItem[] = [];
  /** 页签切换回调：内部点击/拖动命中新页签时触发，宿主据此切换页面 */
  onTabChange: (index: number) => void = (_index: number): void => {};

  // ---- 状态 ----
  @State indicatorX: number = 0;
  @State innerWidth: number = 0;
  @State isDragging: boolean = false;
  /** 窗口高度（vp），用于按机身尺寸推算栏高/底距 */
  @State rootH: number = 0;
  /** 底部导航条（手势条）避让高度：胶囊栏落在它上方 */
  @State navInset: number = 0;
  @State pillScaleX: number = REST_SCALE;
  @State pillScaleY: number = REST_SCALE;
  private barClearance: number = 0;
  private win: window.Window | null = null;

  // ---- 拖动临时量 ----
  private dragStartX: number = 0;
  private maxDragDist: number = 0;
  private lastMoveX: number = 0;
  private lastMoveTime: number = 0;
  private flingVelocity: number = 0;

  aboutToAppear(): void {
    this.refreshGeometry();
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      this.win = win;
      win.on('windowSizeChange', (_size: window.Size): void => {
        this.refreshGeometry();
      });
    });
  }

  aboutToDisappear(): void {
    if (this.win !== null) {
      this.win.off('windowSizeChange');
      this.win = null;
    }
  }

  /** 读取窗口高度与导航条避让，并发布页面底部预留（供各页统一使用）。 */
  private refreshGeometry(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.navInset = this.getUIContext().px2vp(nav.bottomRect.height);
      this.rootH = this.getUIContext().px2vp(win.getWindowProperties().windowRect.height);
      this.publishBarClearance();
    });
  }

  // ---- 几何 ----

  /** 悬浮栏高度：按窗口高度自适应（64~76vp） */
  private barHeightVp(): number {
    if (this.rootH <= 0) {
      return BAR_HEIGHT_BASE;
    }
    const scaled = Math.round(this.rootH * 0.085);
    return Math.max(64, Math.min(76, scaled));
  }

  /** 悬浮栏距底距离（0~2vp）+ 导航条避让：让栏尽量靠下 */
  private barBottomVp(): number {
    if (this.rootH <= 0) {
      return BAR_BOTTOM_BASE;
    }
    const scaled = Math.round(this.rootH * 0.002);
    return Math.max(0, Math.min(2, scaled));
  }

  /** 悬浮栏到屏幕底的真实间距（含导航条避让区） */
  private barBottomEdgeVp(): number {
    return this.barBottomVp() + this.navInset;
  }

  /**
   * 页面滚动内容需要预留的底部空间（内容铺到屏底，靠这段把最后一条滚到胶囊上方）。
   * 发布到 AppStorage，供各页统一使用，保证所有页面底部一致。
   */
  private publishBarClearance(): void {
    const clearance = Math.ceil(this.barBottomEdgeVp() + this.barHeightVp() + 6);
    if (clearance !== this.barClearance) {
      this.barClearance = clearance;
      AppStorage.setOrCreate<number>(KEY_BAR_CLEARANCE, clearance);
    }
  }

  /** 胶囊高度与顶部内距（垂直居中于栏内） */
  private pillHeightVp(): number {
    return this.barHeightVp() - PILL_HEIGHT_INSET;
  }

  private pillTopVp(): number {
    return PILL_HEIGHT_INSET / 2;
  }

  /** 单个页签格宽度 */
  private cellWidth(): number {
    return this.innerWidth / this.items.length;
  }

  /** 第 index 格中心 X */
  private cellCenter(index: number): number {
    return this.cellWidth() * index + this.cellWidth() / 2;
  }

  /** 胶囊当前覆盖的页签索引 */
  private activeIndex(): number {
    if (this.cellWidth() <= 0) {
      return this.selectedIndex;
    }
    const raw = Math.round((this.indicatorX - this.cellWidth() / 2) / this.cellWidth());
    return Math.max(0, Math.min(this.items.length - 1, raw));
  }

  /** smoothstep：边缘过渡更柔和 */
  private smooth(t: number): number {
    const x = Math.max(0, Math.min(1, t));
    return x * x * (3 - 2 * x);
  }

  /** 图标形变强度 0~1（影响半径 = 0.9 格宽） */
  private deformRatio(index: number): number {
    const radius = this.cellWidth() * 0.9;
    if (radius <= 0) {
      return 0;
    }
    const dist = Math.abs(this.indicatorX - this.cellCenter(index));
    return this.smooth(1 - dist / radius);
  }

  /** 选中态用主题主色，未选中用次要文字色（深浅色主题自适应） */
  private iconColor(index: number): ResourceColor {
    return this.activeIndex() === index
      ? $r('app.color.color_primary')
      : $r('app.color.color_text_secondary');
  }

  /** 中间（过境）按钮：仅“选中时”用强调色 #FFD54F，未选中回落为次要色 */
  private itemIconColor(index: number): ResourceColor {
    if (index === CENTER_INDEX) {
      return this.activeIndex() === index ? CENTER_ACCENT : $r('app.color.color_text_secondary');
    }
    return this.iconColor(index);
  }

  /** 中间按钮文字：同上，仅选中时用强调色 */
  private itemLabelColor(index: number): ResourceColor {
    if (index === CENTER_INDEX) {
      return this.activeIndex() === index ? CENTER_ACCENT : $r('app.color.color_text_secondary');
    }
    return this.iconColor(index);
  }

  // ---- 动画 ----

  /** 移动胶囊到目标 X */
  private moveIndicator(x: number, curve: ICurve): void {
    this.getUIContext().animateTo({ curve: curve }, (): void => {
      this.indicatorX = x;
    });
  }

  /** 统一入口设置胶囊缩放（避免多个 animateTo 竞争同一属性） */
  private setPillScale(x: number, y: number, curve: ICurve, duration?: number): void {
    this.getUIContext().animateTo({ curve: curve, duration: duration }, (): void => {
      this.pillScaleX = x;
      this.pillScaleY = y;
    });
  }

  /** 拖动中的三维形变：累计距离放大 + 速度变扁 + 纵向偏移形变 */
  private updatePillStretch(totalDistance: number, velocity: number, verticalOffset: number): void {
    const grow = Math.min(0.85, Math.abs(totalDistance) / 55);
    const s = Math.max(REST_SCALE, 1 + grow);
    const velRatio = Math.min(1, Math.abs(velocity) / 1.5);
    const flatness = 0.2 * velRatio;
    const yDeform = Math.max(-0.15, Math.min(0.15, -verticalOffset / 200));
    this.setPillScale(s * (1 + flatness), s * (1 - flatness + yDeform), curves.springMotion(0.28, 0.62));
  }

  /** 松手回弹：快速甩动先挤压再 Q 弹回静止尺寸 */
  private resetPillStretch(): void {
    if (Math.abs(this.flingVelocity) > 0.6) {
      const squeezeX = 1 - Math.min(0.35, Math.abs(this.flingVelocity) * 0.3);
      const squeezeY = 1 + Math.min(0.25, Math.abs(this.flingVelocity) * 0.2);
      this.setPillScale(squeezeX, squeezeY, curves.springMotion(0.25, 0.5), 90);
    }
    this.setPillScale(REST_SCALE, REST_SCALE, curves.springMotion(1.0, 0.7));
  }

  /** 外部（宿主）切换页签时，让胶囊归位到该格中心 */
  onIndexChanged(): void {
    if (this.isDragging || this.innerWidth <= 0) {
      return;
    }
    this.moveIndicator(this.cellCenter(this.selectedIndex), curves.springMotion(0.32, 0.6));
  }

  /** 点击切换：形变后请求宿主切页，胶囊由 onIndexChanged 归位 */
  private selectTab(index: number): void {
    const targetX = this.cellCenter(index);
    const distance = Math.abs(targetX - this.indicatorX);
    this.updatePillStretch(distance, 0, 0);
    this.onTabChange(index);
    // 根据距离估算弹簧到达时间，到了再缩小，避免还没到就变小
    const arriveMs = Math.max(60, Math.min(200, distance * 0.8));
    setTimeout((): void => {
      this.resetPillStretch();
    }, arriveMs);
  }

  build() {
    Column() {
      Stack() {
        // 胶囊形底：整条栏做成胶囊（两端全圆）的鸿蒙毛玻璃（透明淡底 + 普通模糊，无沉浸材质包边）
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(999)
          .backgroundColor(BAR_CAPSULE_TINT)
          .backgroundBlurStyle(BlurStyle.Thin)
          .shadow({ radius: 14, color: '#26000000', offsetY: 4 })

        // 高亮胶囊：跟随手势滑动，标识当前页签
        // x 需加上 BAR_CELL_INSET：图标行整体内缩，胶囊要落在同一坐标系里，
        // 否则在最左/最右页签时胶囊会顶到胶囊底的圆角外，看起来"没填满"
        Column()
          .width(this.cellWidth() * PILL_WIDTH_RATIO)
          .height(this.pillHeightVp())
          .borderRadius(999)
          .backgroundColor($r('app.color.color_card'))
          .opacity(0.95)
          .scale({ x: this.pillScaleX, y: this.pillScaleY })
          .position({
            x: BAR_CELL_INSET + this.indicatorX - (this.cellWidth() * PILL_WIDTH_RATIO) / 2,
            y: this.pillTopVp()
          })

        // 图标 + 文字（左右各内缩 BAR_CELL_INSET，让最外侧的高亮完整落在胶囊底内）
        Row() {
          Row() {
            ForEach(this.items, (item: GlassTabItem, index: number) => {
              Column() {
                Stack() {
                  // 中间（过境）底圈：未选中时淡强调色光晕；选中时由滑动胶囊负责高亮
                  if (index === CENTER_INDEX) {
                    Column()
                      .width(40)
                      .height(40)
                      .borderRadius(20)
                      .backgroundColor(CENTER_ACCENT)
                      .opacity(this.activeIndex() === index ? 0.18 : 0)
                  }
                  // 像素风图标用 Image（可随主题/选中态 fillColor 着色）；系统符号仍用 SymbolGlyph
                  if (item.pixel) {
                    Image(item.icon)
                      .width(index === CENTER_INDEX ? 28 : (this.activeIndex() === index ? 26 : 20))
                      .height(index === CENTER_INDEX ? 28 : (this.activeIndex() === index ? 26 : 20))
                      .fillColor(this.itemIconColor(index))
                      .scale({ x: 1 + 0.14 * this.deformRatio(index), y: 1 + 0.14 * this.deformRatio(index) })
                      .translate({ y: -2 * this.deformRatio(index) })
                  } else {
                    SymbolGlyph(item.icon)
                      .fontSize(index === CENTER_INDEX ? 24 : (this.activeIndex() === index ? 23 : 17))
                      .fontColor([this.itemIconColor(index)])
                      .scale({ x: 1 + 0.14 * this.deformRatio(index), y: 1 + 0.14 * this.deformRatio(index) })
                      .translate({ y: -2 * this.deformRatio(index) })
                  }
                }
                .height(40)
                .alignContent(Alignment.Center)

                Text(item.title)
                  .fontSize(index === CENTER_INDEX ? 12 : 11)
                  .fontWeight(index === CENTER_INDEX ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.itemLabelColor(index))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .onClick((): void => {
                this.selectTab(index);
              })
            }, (item: GlassTabItem): string => item.title)
          }
          .width('100%')
          .height('100%')
          // 实测「图标行内容宽」→ 计算格宽（不含内缩，胶囊位置另加 BAR_CELL_INSET）
          .onAreaChange((_oldValue: Area, newValue: Area): void => {
            const w = Number(newValue.width);
            if (w > 0 && Math.abs(w - this.innerWidth) > 0.5) {
              this.innerWidth = w;
              if (!this.isDragging) {
                this.indicatorX = this.cellCenter(this.selectedIndex);
                this.pillScaleX = REST_SCALE;
                this.pillScaleY = REST_SCALE;
              }
            }
          })
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
        .padding({ left: BAR_CELL_INSET, right: BAR_CELL_INSET })
        .gesture(
          PanGesture({ direction: PanDirection.All })
            .onActionStart((): void => {
              this.isDragging = true;
              this.dragStartX = this.indicatorX;
              this.maxDragDist = 0;
              this.lastMoveX = this.indicatorX;
              this.lastMoveTime = Date.now();
              this.flingVelocity = 0;
            })
            .onActionUpdate((event: GestureEvent): void => {
              if (!this.isDragging || this.innerWidth <= 0) {
                return;
              }
              const minC = this.cellCenter(0);
              const maxC = this.cellCenter(this.items.length - 1);
              let target = this.dragStartX + event.offsetX;
              target = Math.max(minC, Math.min(maxC, target));
              this.moveIndicator(target, curves.responsiveSpringMotion(0.32, 0.6));
              const now = Date.now();
              const dt = now - this.lastMoveTime;
              if (dt > 0) {
                this.flingVelocity = (target - this.lastMoveX) / dt;
              }
              this.lastMoveX = target;
              this.lastMoveTime = now;
              const curDist = Math.abs(target - this.dragStartX);
              this.maxDragDist = Math.max(this.maxDragDist, curDist);
              this.updatePillStretch(this.maxDragDist, this.flingVelocity, event.offsetY);
            })
            .onActionEnd((): void => {
              this.isDragging = false;
              const idx = this.activeIndex();
              this.onTabChange(idx);
              this.moveIndicator(this.cellCenter(idx), curves.springMotion(0.32, 0.6));
              this.resetPillStretch();
            })
        )
      }
      .width('100%')
      .height(this.barHeightVp())
    }
    .width('100%')
    .padding({ left: BAR_SIDE_MARGIN, right: BAR_SIDE_MARGIN, bottom: this.barBottomEdgeVp() })
    .hitTestBehavior(HitTestMode.Transparent)
  }
}