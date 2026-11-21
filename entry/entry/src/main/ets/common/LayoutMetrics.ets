/*
 * 版式常量：与底部悬浮胶囊任务栏相关的留白。
 * 任务是浮在内容之上的，页面本体要铺到屏幕底部，
 * 但滚动内容需要预留一段底部空间，保证最后一条能滚到胶囊上方。
 *
 * 运行时会由 Index 按「栏高 + 底距 + 导航条避让 + 余量」算出真实值，
 * 写入 AppStorage[KEY_BAR_CLEARANCE]；TAB_BAR_CLEARANCE 只是兜底默认值。
 */

/** AppStorage key：各页读取的底部预留高度（vp） */
export const KEY_BAR_CLEARANCE = 'tab_bar_clearance';

/** 兜底默认值：真实值由 Index 在运行时发布 */
export const TAB_BAR_CLEARANCE = 96;
