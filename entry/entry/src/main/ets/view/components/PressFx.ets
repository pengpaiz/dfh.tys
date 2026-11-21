/*
 * 按钮按压/入场动画参数。与卫星列表选择动画共用同一套 Friction 手感，
 * 各页面统一引用，避免出现多种时长/曲线。
 */

/** 按下（收紧）时长：略快于回弹，手指按下即有反馈。 */
export const PRESS_IN_MS = 120;
/** 抬起（回弹）时长：与卫星列表选择动画一致。 */
export const PRESS_OUT_MS = 320;
/** 按住时的缩放比例。 */
export const PRESS_SCALE = 0.9;
/** 入场动画起始缩放（放大到 1）。 */
export const ENTER_SCALE = 0.86;
