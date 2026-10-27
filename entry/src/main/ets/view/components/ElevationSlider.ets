/*
 * 最低过境仰角滑动条（性能隔离版）。
 *
 * 为什么要单独拆一个组件：
 * 之前 Slider.onChange 每帧都写父页面的 @State，导致整张设置页（6 个分区、
 * 多个 TextInput）逐帧重建 → 拖动明显掉帧。
 * 现在拖动的实时数值只存在本组件的 @State 里，只有本组件重绘；
 * **松手（SliderChangeMode.End）才通过 onCommit 通知父级**，
 * 由父级去写全局设置（并触发过境/日历页在后台重算）。
 * 这样拖动期间不触发任何批量计算，符合"拖动轻量预览 + 松手完整计算"。
 */

@Component
export struct ElevationSlider {
  /** 初始值 / 外部设置值（父级在设置页加载或提交后传入） */
  @Prop @Watch('onExternalValueChanged') initialValue: number = 5;
  /** 拖动中的实时值：只影响本组件 */
  @State currentValue: number = 5;
  /** 松手后回调（父级用它写 AppSettings 并更新摘要） */
  onCommit: (v: number) => void = () => {
  };

  private minValue: number = 0;
  private maxValue: number = 40;

  aboutToAppear(): void {
    this.currentValue = this.initialValue;
  }

  /** 外部值变化（例如别处改了设置）时同步显示，不产生回调。 */
  onExternalValueChanged(): void {
    this.currentValue = this.initialValue;
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('最低过境仰角').fontSize(14).fontColor($r('app.color.cc_text_title'))
        Blank()
        Text(`${this.currentValue}°`).fontSize(14).fontColor($r('app.color.cc_accent_text'))
      }
      .width('100%')

      Slider({
        value: this.currentValue,
        min: this.minValue,
        max: this.maxValue,
        step: 1,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode): void => {
          const next = Math.round(value);
          if (this.currentValue !== next) {
            // 拖动中只更新本组件的轻量状态
            this.currentValue = next;
          }
          if (mode === SliderChangeMode.End) {
            // 松手才提交：父级此时才会写设置/触发重算
            this.onCommit(this.currentValue);
          }
        })
    }
    .width('100%')
  }
}
