/*
 * Look4Sat. 通联录音（应用内录音，保存在本机应用目录）。
 *
 * 用 MediaKit 的 AVRecorder 录麦克风音频（AAC / m4a），文件落在
 * context.filesDir/recordings/ 下——应用自己的目录不需要存储权限，
 * 也不涉及公共媒体库的受限权限（READ_AUDIO/WRITE_AUDIO）。
 *
 * 注意（来自开发指南）：
 * - 必须在前台启动录制；后台启动会失败；持续/后台录制需要长时任务，
 *   本实现只在详情页前台录制，页面退出即停止并释放麦克风。
 * - 权限：ohos.permission.MICROPHONE（user_grant），
 *   需在 module.json5 声明 reason/usedScene，并在运行时申请。
 */

import { media } from '@kit.MediaKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

const MIC_PERMISSION: Permissions[] = ['ohos.permission.MICROPHONE'];
const REC_DIR = 'recordings';

export class AudioRecorder {
  private static instanceValue: AudioRecorder | null = null;
  private recorder: media.AVRecorder | null = null;
  private file: fs.File | null = null;
  private recording: boolean = false;
  private startTs: number = 0;
  private savedName: string = '';

  static getInstance(): AudioRecorder {
    if (AudioRecorder.instanceValue === null) {
      AudioRecorder.instanceValue = new AudioRecorder();
    }
    return AudioRecorder.instanceValue;
  }

  isRecording(): boolean {
    return this.recording;
  }

  elapsedMillis(): number {
    return this.recording ? Date.now() - this.startTs : 0;
  }

  /** 最近一次保存的文件名（不含目录） */
  lastSavedName(): string {
    return this.savedName;
  }

  /** 申请麦克风权限（user_grant）。 */
  static async ensurePermission(context: common.Context): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const res = await atManager.requestPermissionsFromUser(context, MIC_PERMISSION);
      for (let i = 0; i < res.authResults.length; i++) {
        if (res.authResults[i] === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
          return false;
        }
      }
      return res.authResults.length > 0;
    } catch (e) {
      Logger.error('AudioRecorder', `request permission failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 开始录音，返回文件名；失败会抛出异常（调用方提示用户）。 */
  async start(context: common.Context): Promise<string> {
    if (this.recording) {
      return this.savedName;
    }
    const dir = `${context.filesDir}/${REC_DIR}`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    const name = `rec_${AudioRecorder.stamp()}.m4a`;
    const path = `${dir}/${name}`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    this.file = file;
    let recorder: media.AVRecorder | null = null;
    try {
      const created: media.AVRecorder = await media.createAVRecorder();
      recorder = created;
      this.recorder = created;
      created.on('stateChange', (state: media.AVRecorderState): void => {
        Logger.debug('AudioRecorder', `state=${state}`);
      });
      created.on('error', (err: BusinessError): void => {
        Logger.error('AudioRecorder', `error: ${err.code} ${err.message}`);
      });
      await created.prepare({
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: {
          audioBitrate: 96000,
          audioChannels: 1,
          audioCodec: media.CodecMimeType.AUDIO_AAC,
          audioSampleRate: 48000,
          fileFormat: media.ContainerFormatType.CFT_MPEG_4A
        },
        url: `fd://${file.fd}`
      });
      await created.start();
      this.recording = true;
      this.startTs = Date.now();
      this.savedName = name;
      return name;
    } catch (e) {
      // 启动失败：回滚已占用的录音器与文件句柄，避免麦克风/文件句柄泄漏
      this.recorder = null;
      this.file = null;
      this.recording = false;
      if (recorder !== null) {
        try {
          await recorder.release();
        } catch (err) {
          Logger.error('AudioRecorder', `release after failed start: ${JSON.stringify(err)}`);
        }
      }
      try {
        fs.closeSync(file);
      } catch (err) {
        // 忽略关闭失败
      }
      // ArkTS 限制 throw 只能抛 Error 及其子类：把任意异常归一成 Error，保留原始信息
      const err: Error = e instanceof Error ? e : new Error(String(e));
      throw err;
    }
  }

  /** 停止录音并释放资源；返回本次保存的文件名（未在录制则返回空串）。 */
  async stop(): Promise<string> {
    const recorder = this.recorder;
    const file = this.file;
    const wasRecording = this.recording;
    this.recorder = null;
    this.file = null;
    this.recording = false;
    const name = wasRecording ? this.savedName : '';
    try {
      if (recorder !== null) {
        if (wasRecording) {
          await recorder.stop();
        }
        await recorder.release();
      }
    } catch (e) {
      Logger.error('AudioRecorder', `stop/release failed: ${JSON.stringify(e)}`);
    }
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        // 忽略关闭失败
      }
    }
    return name;
  }

  /** 页面退出时调用：正在录就先停掉，避免长期占用麦克风。 */
  async releaseIfRecording(): Promise<void> {
    if (this.recording) {
      await this.stop();
    }
  }

  /** 删除本机全部录音文件（供"清除本机数据"使用）。返回删除的文件数。 */
  static clearRecordings(context: common.Context): number {
    const dir = `${context.filesDir}/${REC_DIR}`;
    let removed = 0;
    try {
      if (!fs.accessSync(dir)) {
        return 0;
      }
      const names = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          fs.unlinkSync(`${dir}/${names[i]}`);
          removed++;
        } catch (e) {
          // 单个文件删除失败不影响其它
        }
      }
    } catch (e) {
      Logger.error('AudioRecorder', `clearRecordings failed: ${JSON.stringify(e)}`);
    }
    return removed;
  }

  /** 文件名用的时间戳：yyyyMMdd_HHmmss */
  private static stamp(): string {
    const d = new Date();
    const p2 = (v: number): string => v < 10 ? `0${v}` : `${v}`;
    return `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}_${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`;
  }
}
