import os
import sys
import shutil
import subprocess
from dataclasses import dataclass

import cv2
import numpy as np

from PySide6.QtCore import Qt, QTimer, QSize, QPoint, QDir, Signal
from PySide6.QtGui import QAction, QImage, QKeySequence, QPainter, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QProgressDialog,
    QSlider,
    QSpinBox,
    QStatusBar,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)


AXIS_INDEX = {
    "y": 0,  # 时间帧
    "z": 1,  # 纵像素
    "x": 2,  # 横像素
}

# (time_axis, h_axis, v_axis)
MODES = [
    ("y", "x", "z"),
    ("y", "z", "x"),
    ("x", "y", "z"),
    ("x", "z", "y"),
    ("z", "x", "y"),
    ("z", "y", "x"),
]


@dataclass
class VideoMeta:
    source_path: str = ""
    original_fps: float = 25.0
    original_frame_count: int = 0
    original_width: int = 0
    original_height: int = 0
    loaded_frame_count: int = 0
    loaded_width: int = 0
    loaded_height: int = 0
    has_alpha: bool = False
    alpha_note: str = "未检测到 Alpha"


class VideoVolume:
    """
    统一保存为 volume[y, z, x, c]
    y = 帧序号（时间）
    z = 纵向像素
    x = 横向像素
    c = RGB 通道
    """

    def __init__(self):
        self.volume: np.ndarray | None = None
        self.alpha_volume: np.ndarray | None = None
        self.meta = VideoMeta()

    def clear(self):
        self.volume = None
        self.alpha_volume = None
        self.meta = VideoMeta()

    def is_loaded(self) -> bool:
        return self.volume is not None

    @staticmethod
    def _compute_scaled_size(src_width: int, src_height: int, max_side: int) -> tuple[int, int, float]:
        scale = 1.0
        longest = max(src_width, src_height)
        if longest > max_side:
            scale = max_side / longest
        dst_width = max(1, int(round(src_width * scale)))
        dst_height = max(1, int(round(src_height * scale)))
        return dst_width, dst_height, scale

    @staticmethod
    def _parse_ratio_to_float(value: str | None, default: float = 25.0) -> float:
        if not value:
            return default
        text = str(value).strip()
        if not text or text == '0/0':
            return default
        try:
            if '/' in text:
                num_s, den_s = text.split('/', 1)
                num = float(num_s)
                den = float(den_s)
                if abs(den) < 1e-12:
                    return default
                out = num / den
            else:
                out = float(text)
        except Exception:
            return default
        if out <= 1e-6:
            return default
        return out

    @staticmethod
    def _pix_fmt_has_alpha(pix_fmt: str | None) -> bool:
        if not pix_fmt:
            return False
        fmt = str(pix_fmt).lower()
        alpha_markers = (
            'rgba', 'bgra', 'argb', 'abgr',
            'yuva', 'gbrap', 'ya', 'ayuv', 'alpha'
        )
        return any(marker in fmt for marker in alpha_markers)

    @staticmethod
    def _ffmpeg_available() -> bool:
        return shutil.which('ffmpeg') is not None and shutil.which('ffprobe') is not None

    def _ffprobe_stream_info(self, path: str) -> dict | None:
        if not self._ffmpeg_available():
            return None
        cmd = [
            'ffprobe', '-v', 'error', '-select_streams', 'v:0',
            '-show_entries', 'stream=width,height,avg_frame_rate,r_frame_rate,pix_fmt,nb_frames',
            '-of', 'default=noprint_wrappers=1:nokey=0', path,
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        except Exception:
            return None
        info: dict[str, str] = {}
        for line in res.stdout.splitlines():
            if '=' in line:
                k, v = line.split('=', 1)
                info[k.strip()] = v.strip()
        return info or None

    def _finalize_loaded_frames(
        self,
        path: str,
        fps: float,
        src_frame_count: int,
        src_width: int,
        src_height: int,
        dst_width: int,
        dst_height: int,
        frames: list[np.ndarray],
        alpha_frames: list[np.ndarray] | None,
        alpha_note: str,
    ):
        if not frames:
            raise RuntimeError('视频中没有可读取的帧')

        self.volume = np.stack(frames, axis=0)
        if alpha_frames is not None:
            alpha_stack = np.stack(alpha_frames, axis=0)
            if np.any(alpha_stack < 255):
                self.alpha_volume = alpha_stack
                has_alpha = True
                alpha_note = f'{alpha_note}；检测到有效透明像素'
            else:
                self.alpha_volume = None
                has_alpha = False
                alpha_note = f'{alpha_note}；但所有像素 alpha 都是不透明'
        else:
            self.alpha_volume = None
            has_alpha = False

        self.meta = VideoMeta(
            source_path=path,
            original_fps=float(fps),
            original_frame_count=src_frame_count if src_frame_count > 0 else len(frames),
            original_width=src_width,
            original_height=src_height,
            loaded_frame_count=len(frames),
            loaded_width=dst_width,
            loaded_height=dst_height,
            has_alpha=has_alpha,
            alpha_note=alpha_note,
        )

    def _load_video_via_ffmpeg_rgba(self, path: str, max_side: int, stream_info: dict | None = None):
        if not self._ffmpeg_available():
            raise RuntimeError('系统中未找到 ffmpeg / ffprobe')

        info = stream_info or self._ffprobe_stream_info(path) or {}
        src_width = int(info.get('width', '0') or 0)
        src_height = int(info.get('height', '0') or 0)
        if src_width <= 0 or src_height <= 0:
            raise RuntimeError('ffprobe 无法读取视频尺寸')

        fps = self._parse_ratio_to_float(info.get('avg_frame_rate') or info.get('r_frame_rate'), default=25.0)
        src_frame_count = int(info.get('nb_frames', '0') or 0)
        dst_width, dst_height, _ = self._compute_scaled_size(src_width, src_height, max_side)

        vf = f'scale={dst_width}:{dst_height}:flags=lanczos,format=rgba'
        cmd = [
            'ffmpeg', '-v', 'error', '-i', path,
            '-vf', vf,
            '-f', 'rawvideo', '-pix_fmt', 'rgba', '-',
        ]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert proc.stdout is not None
        frame_bytes = dst_width * dst_height * 4

        frames: list[np.ndarray] = []
        alpha_frames: list[np.ndarray] = []
        while True:
            raw = proc.stdout.read(frame_bytes)
            if not raw:
                break
            if len(raw) < frame_bytes:
                break
            rgba = np.frombuffer(raw, dtype=np.uint8).reshape((dst_height, dst_width, 4)).copy()
            frames.append(rgba[:, :, :3].copy())
            alpha_frames.append(rgba[:, :, 3].copy())

        stderr_text = ''
        if proc.stderr is not None:
            try:
                stderr_text = proc.stderr.read().decode('utf-8', errors='ignore')
            except Exception:
                stderr_text = ''
        retcode = proc.wait()

        if retcode != 0 and not frames:
            raise RuntimeError(f'ffmpeg RGBA 解码失败：{stderr_text.strip() or retcode}')
        if not frames:
            raise RuntimeError('ffmpeg RGBA 解码没有读到任何帧')

        pix_fmt = (info.get('pix_fmt') or 'unknown').lower()
        alpha_note = f'已通过 ffmpeg RGBA 管线读取（pix_fmt={pix_fmt}）'
        self._finalize_loaded_frames(
            path=path,
            fps=fps,
            src_frame_count=src_frame_count,
            src_width=src_width,
            src_height=src_height,
            dst_width=dst_width,
            dst_height=dst_height,
            frames=frames,
            alpha_frames=alpha_frames,
            alpha_note=alpha_note,
        )

    def _load_video_via_opencv(self, path: str, max_side: int):
        cap = cv2.VideoCapture(path)
        if not cap.isOpened():
            raise RuntimeError('无法打开视频文件')

        fps = cap.get(cv2.CAP_PROP_FPS)
        if fps is None or fps <= 1e-6:
            fps = 25.0

        src_frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        src_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        src_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        if src_width <= 0 or src_height <= 0:
            cap.release()
            raise RuntimeError('无法读取视频尺寸')

        dst_width, dst_height, scale = self._compute_scaled_size(src_width, src_height, max_side)

        frames: list[np.ndarray] = []
        alpha_frames: list[np.ndarray] | None = None
        alpha_note = '未检测到 Alpha（OpenCV 标准读取路径未返回 4 通道帧）'

        while True:
            ok, frame_raw = cap.read()
            if not ok:
                break

            if scale != 1.0:
                frame_raw = cv2.resize(frame_raw, (dst_width, dst_height), interpolation=cv2.INTER_AREA)

            if frame_raw.ndim == 3 and frame_raw.shape[2] == 4:
                frame_rgba = cv2.cvtColor(frame_raw, cv2.COLOR_BGRA2RGBA)
                frames.append(frame_rgba[:, :, :3].copy())
                if alpha_frames is None:
                    alpha_frames = []
                    alpha_note = '已检测到 Alpha（OpenCV 解码直接返回了 4 通道帧）'
                alpha_frames.append(frame_rgba[:, :, 3].copy())
            else:
                if frame_raw.ndim == 2:
                    frame_rgb = cv2.cvtColor(frame_raw, cv2.COLOR_GRAY2RGB)
                else:
                    frame_rgb = cv2.cvtColor(frame_raw, cv2.COLOR_BGR2RGB)
                frames.append(frame_rgb)
                if alpha_frames is not None:
                    alpha_frames.append(np.full(frame_rgb.shape[:2], 255, dtype=np.uint8))

        cap.release()
        self._finalize_loaded_frames(
            path=path,
            fps=float(fps),
            src_frame_count=src_frame_count,
            src_width=src_width,
            src_height=src_height,
            dst_width=dst_width,
            dst_height=dst_height,
            frames=frames,
            alpha_frames=alpha_frames,
            alpha_note=alpha_note,
        )

    def load_video(self, path: str, max_side: int = 960):
        self.clear()

        errors: list[str] = []
        stream_info = self._ffprobe_stream_info(path)
        pix_fmt = (stream_info or {}).get('pix_fmt', '')
        stream_has_alpha = self._pix_fmt_has_alpha(pix_fmt)
        ffmpeg_ready = self._ffmpeg_available()
        should_try_ffmpeg_rgba = ffmpeg_ready and stream_has_alpha

        if should_try_ffmpeg_rgba:
            try:
                self._load_video_via_ffmpeg_rgba(path, max_side=max_side, stream_info=stream_info)
                return
            except Exception as exc:
                errors.append(f'ffmpeg RGBA 管线失败：{exc}')

        try:
            self._load_video_via_opencv(path, max_side=max_side)
            if stream_has_alpha and self.meta is not None and not self.meta.has_alpha:
                if ffmpeg_ready:
                    prefix = f'ffprobe 显示视频像素格式为 {pix_fmt}，理论上包含 Alpha；但当前回退到了 OpenCV，未成功读取 Alpha。'
                else:
                    prefix = f'ffprobe 显示视频像素格式为 {pix_fmt}，理论上包含 Alpha；但系统未找到 ffmpeg/ffprobe，当前只能回退到 OpenCV，因此无法稳定读取 Alpha。'
                tail = self.meta.alpha_note or ''
                self.meta.alpha_note = prefix + (("\n" + tail) if tail else '')
            return
        except Exception as exc:
            errors.append(f'OpenCV 管线失败：{exc}')

        raise RuntimeError('导入视频失败。\n' + '\n'.join(errors))

    def get_view(self, time_axis: str, h_axis: str, v_axis: str) -> np.ndarray:
        if self.volume is None:
            raise RuntimeError("尚未加载视频")

        if len({time_axis, h_axis, v_axis}) != 3:
            raise ValueError("时间轴、横轴、纵轴必须互不相同")

        order = [AXIS_INDEX[v_axis], AXIS_INDEX[h_axis], AXIS_INDEX[time_axis], 3]
        return np.transpose(self.volume, axes=order)

    def memory_usage_bytes(self) -> int:
        total = 0
        if self.volume is not None:
            total += int(self.volume.nbytes)
        if self.alpha_volume is not None:
            total += int(self.alpha_volume.nbytes)
        return total

    @staticmethod
    def quat_normalize(q: np.ndarray) -> np.ndarray:
        norm = float(np.linalg.norm(q))
        if norm < 1e-12:
            return np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float64)
        return (q / norm).astype(np.float64)

    @staticmethod
    def quat_to_matrix(q: np.ndarray) -> np.ndarray:
        q = VideoVolume.quat_normalize(np.asarray(q, dtype=np.float64))
        w, x, y, z = q
        return np.array(
            [
                [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w), 2.0 * (x * z + y * w)],
                [2.0 * (x * y + z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - x * w)],
                [2.0 * (x * z - y * w), 2.0 * (y * z + x * w), 1.0 - 2.0 * (x * x + y * y)],
            ],
            dtype=np.float64,
        )

    def _trilinear_sample_rgb(
        self,
        volume_f32: np.ndarray,
        t_coords: np.ndarray,
        z_coords: np.ndarray,
        x_coords: np.ndarray,
    ) -> tuple[np.ndarray, np.ndarray]:
        t_max = volume_f32.shape[0] - 1
        z_max = volume_f32.shape[1] - 1
        x_max = volume_f32.shape[2] - 1

        valid = (
            (t_coords >= 0.0) & (t_coords <= t_max) &
            (z_coords >= 0.0) & (z_coords <= z_max) &
            (x_coords >= 0.0) & (x_coords <= x_max)
        )

        t0 = np.floor(t_coords).astype(np.int32)
        z0 = np.floor(z_coords).astype(np.int32)
        x0 = np.floor(x_coords).astype(np.int32)

        t1 = t0 + 1
        z1 = z0 + 1
        x1 = x0 + 1

        t0c = np.clip(t0, 0, t_max)
        z0c = np.clip(z0, 0, z_max)
        x0c = np.clip(x0, 0, x_max)
        t1c = np.clip(t1, 0, t_max)
        z1c = np.clip(z1, 0, z_max)
        x1c = np.clip(x1, 0, x_max)

        wt = (t_coords - t0).astype(np.float32)[..., None]
        wz = (z_coords - z0).astype(np.float32)[..., None]
        wx = (x_coords - x0).astype(np.float32)[..., None]

        c000 = volume_f32[t0c, z0c, x0c]
        c001 = volume_f32[t0c, z0c, x1c]
        c010 = volume_f32[t0c, z1c, x0c]
        c011 = volume_f32[t0c, z1c, x1c]
        c100 = volume_f32[t1c, z0c, x0c]
        c101 = volume_f32[t1c, z0c, x1c]
        c110 = volume_f32[t1c, z1c, x0c]
        c111 = volume_f32[t1c, z1c, x1c]

        c00 = c000 * (1.0 - wx) + c001 * wx
        c01 = c010 * (1.0 - wx) + c011 * wx
        c10 = c100 * (1.0 - wx) + c101 * wx
        c11 = c110 * (1.0 - wx) + c111 * wx

        c0 = c00 * (1.0 - wz) + c01 * wz
        c1 = c10 * (1.0 - wz) + c11 * wz
        out = c0 * (1.0 - wt) + c1 * wt

        out *= valid[..., None].astype(np.float32)
        out = np.clip(out, 0.0, 255.0).astype(np.uint8)
        return out, valid

    def _trilinear_sample_scalar(
        self,
        volume_f32: np.ndarray,
        t_coords: np.ndarray,
        z_coords: np.ndarray,
        x_coords: np.ndarray,
    ) -> np.ndarray:
        t_max = volume_f32.shape[0] - 1
        z_max = volume_f32.shape[1] - 1
        x_max = volume_f32.shape[2] - 1

        valid = (
            (t_coords >= 0.0) & (t_coords <= t_max) &
            (z_coords >= 0.0) & (z_coords <= z_max) &
            (x_coords >= 0.0) & (x_coords <= x_max)
        )

        t0 = np.floor(t_coords).astype(np.int32)
        z0 = np.floor(z_coords).astype(np.int32)
        x0 = np.floor(x_coords).astype(np.int32)

        t1 = t0 + 1
        z1 = z0 + 1
        x1 = x0 + 1

        t0c = np.clip(t0, 0, t_max)
        z0c = np.clip(z0, 0, z_max)
        x0c = np.clip(x0, 0, x_max)
        t1c = np.clip(t1, 0, t_max)
        z1c = np.clip(z1, 0, z_max)
        x1c = np.clip(x1, 0, x_max)

        wt = (t_coords - t0).astype(np.float32)
        wz = (z_coords - z0).astype(np.float32)
        wx = (x_coords - x0).astype(np.float32)

        c000 = volume_f32[t0c, z0c, x0c]
        c001 = volume_f32[t0c, z0c, x1c]
        c010 = volume_f32[t0c, z1c, x0c]
        c011 = volume_f32[t0c, z1c, x1c]
        c100 = volume_f32[t1c, z0c, x0c]
        c101 = volume_f32[t1c, z0c, x1c]
        c110 = volume_f32[t1c, z1c, x0c]
        c111 = volume_f32[t1c, z1c, x1c]

        c00 = c000 * (1.0 - wx) + c001 * wx
        c01 = c010 * (1.0 - wx) + c011 * wx
        c10 = c100 * (1.0 - wx) + c101 * wx
        c11 = c110 * (1.0 - wx) + c111 * wx

        c0 = c00 * (1.0 - wz) + c01 * wz
        c1 = c10 * (1.0 - wz) + c11 * wz
        out = c0 * (1.0 - wt) + c1 * wt

        out *= valid.astype(np.float32)
        out = np.clip(out, 0.0, 255.0).astype(np.uint8)
        return out

    def build_oblique_view(
        self,
        plane_quat: np.ndarray,
        progress_cb=None,
        cancel_cb=None,
        max_output_bytes: int = 420 * 1024 * 1024,
    ) -> tuple[np.ndarray, np.ndarray | None, dict]:
        if self.volume is None:
            raise RuntimeError("尚未加载视频")

        vol = self.volume
        t_size, z_size, x_size = vol.shape[:3]
        hx = 0.5 * max(0, x_size - 1)
        hy = 0.5 * max(0, t_size - 1)
        hz = 0.5 * max(0, z_size - 1)
        center = np.array([hx, hy, hz], dtype=np.float32)

        vertices = np.array(
            [
                [-hx, -hy, -hz],
                [ hx, -hy, -hz],
                [ hx,  hy, -hz],
                [-hx,  hy, -hz],
                [-hx, -hy,  hz],
                [ hx, -hy,  hz],
                [ hx,  hy,  hz],
                [-hx,  hy,  hz],
            ],
            dtype=np.float32,
        )

        rot = self.quat_to_matrix(plane_quat).astype(np.float32)
        base_vectors = np.array(
            [
                [1.0, 0.0, 0.0],  # u：x
                [0.0, 0.0, 1.0],  # v：z(纵像素)
                [0.0, 1.0, 0.0],  # n：t(时间法向默认)
            ],
            dtype=np.float32,
        )
        u_vec, v_vec, n_vec = base_vectors @ rot.T

        proj_u = vertices @ u_vec
        proj_v = vertices @ v_vec
        proj_n = vertices @ n_vec

        min_u, max_u = float(np.min(proj_u)), float(np.max(proj_u))
        min_v, max_v = float(np.min(proj_v)), float(np.max(proj_v))
        min_n, max_n = float(np.min(proj_n)), float(np.max(proj_n))

        raw_width = max(8, int(np.ceil(max_u - min_u)) + 1)
        raw_height = max(8, int(np.ceil(max_v - min_v)) + 1)
        raw_frames = max(2, int(np.ceil(max_n - min_n)) + 1)

        raw_bytes = raw_width * raw_height * raw_frames * 3
        sample_scale = 1.0
        if raw_bytes > max_output_bytes:
            sample_scale = float((raw_bytes / max_output_bytes) ** (1.0 / 3.0))

        width = max(8, int(np.ceil(raw_width / sample_scale)))
        height = max(8, int(np.ceil(raw_height / sample_scale)))
        total_frames = max(2, int(np.ceil(raw_frames / sample_scale)))

        u_coords = np.linspace(min_u, max_u, width, dtype=np.float32)
        v_coords = np.linspace(max_v, min_v, height, dtype=np.float32)
        n_coords = np.linspace(min_n, max_n, total_frames, dtype=np.float32)

        uu, vv = np.meshgrid(u_coords, v_coords)
        vol_f32 = vol.astype(np.float32, copy=False)

        frames = []
        alpha_frames = [] if self.alpha_volume is not None else None
        bbox = None

        for i, s in enumerate(n_coords):
            if cancel_cb is not None and cancel_cb():
                raise InterruptedError("用户取消生成参考面切片")

            world_x = center[0] + uu * u_vec[0] + vv * v_vec[0] + s * n_vec[0]
            world_t = center[1] + uu * u_vec[1] + vv * v_vec[1] + s * n_vec[1]
            world_z = center[2] + uu * u_vec[2] + vv * v_vec[2] + s * n_vec[2]

            frame, valid = self._trilinear_sample_rgb(vol_f32, world_t, world_z, world_x)
            frames.append(frame)

            if alpha_frames is not None and self.alpha_volume is not None:
                alpha_frame = self._trilinear_sample_scalar(
                    self.alpha_volume.astype(np.float32, copy=False),
                    world_t, world_z, world_x
                )
                alpha_frames.append(alpha_frame)

            if np.any(valid):
                ys, xs = np.nonzero(valid)
                cur_box = (int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max()))
                if bbox is None:
                    bbox = cur_box
                else:
                    bbox = (
                        min(bbox[0], cur_box[0]),
                        max(bbox[1], cur_box[1]),
                        min(bbox[2], cur_box[2]),
                        max(bbox[3], cur_box[3]),
                    )

            if progress_cb is not None:
                progress_cb(i + 1, total_frames)

        stack = np.stack(frames, axis=2)  # [h, w, t, c]
        alpha_stack = np.stack(alpha_frames, axis=2) if alpha_frames is not None else None

        if bbox is not None:
            y0, y1, x0, x1 = bbox
            stack = stack[y0:y1 + 1, x0:x1 + 1, :, :]
            if alpha_stack is not None:
                alpha_stack = alpha_stack[y0:y1 + 1, x0:x1 + 1, :]
        else:
            y0, y1, x0, x1 = 0, height - 1, 0, width - 1

        if alpha_stack is not None and not np.any(alpha_stack < 255):
            alpha_stack = None

        info = {
            "u_vec": u_vec.astype(np.float32),
            "v_vec": v_vec.astype(np.float32),
            "n_vec": n_vec.astype(np.float32),
            "raw_shape": (raw_height, raw_width, raw_frames, 3),
            "cropped_shape": tuple(stack.shape),
            "bbox": (y0, y1, x0, x1),
            "sample_scale": sample_scale,
            "n_range": (min_n, max_n),
        }
        return stack, alpha_stack, info


class CubeViewWidget(QWidget):
    """
    轻量 3D 视图：
    - 六个面预览
    - X / Y / T 坐标轴
    - 可自由旋转的参考面
      - 中键拖动：旋转相机视角
      - 左键按住 X / Y / T 轴拖动：绕对应轴旋转视角
      - 右键拖动：自由旋转参考面
    - 滚轮缩放
    """

    referencePlaneChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumSize(QSize(720, 520))
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

        self.volume: np.ndarray | None = None
        self.alpha_volume: np.ndarray | None = None
        self.face_images: dict[str, np.ndarray] = {}
        self.face_alpha_images: dict[str, np.ndarray] = {}
        self.volume_slice_cache: dict[str, list[dict[str, object]]] = {}
        self.alpha_enabled = True
        self.dims_xyz = (1, 1, 1)  # x, y(time), z

        self.orientation = self._default_orientation()
        self.plane_orientation = np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float64)
        self.zoom = 1.0
        self.camera_distance = 4.2
        self._drag_mode: str | None = None   # None / orbit / axis / plane
        self._active_axis: str | None = None
        self._hover_axis: str | None = None
        self._plane_axis_lock: str | None = None  # X / Y / T
        self._last_pos = QPoint()
        self._axis_screen_cache: dict[str, object] = {}
        self.preview_face_limit = 320

    def _default_orientation(self) -> np.ndarray:
        q_yaw = self._quat_from_axis_angle(np.array([0.0, 0.0, 1.0], dtype=np.float64), np.deg2rad(-35.0))
        q_pitch = self._quat_from_axis_angle(np.array([1.0, 0.0, 0.0], dtype=np.float64), np.deg2rad(28.0))
        return self._quat_normalize(self._quat_multiply(q_pitch, q_yaw))

    def _quat_normalize(self, q: np.ndarray) -> np.ndarray:
        return VideoVolume.quat_normalize(q)

    def _quat_multiply(self, q1: np.ndarray, q2: np.ndarray) -> np.ndarray:
        w1, x1, y1, z1 = q1
        w2, x2, y2, z2 = q2
        return np.array(
            [
                w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
                w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
                w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
                w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
            ],
            dtype=np.float64,
        )

    def _quat_from_axis_angle(self, axis: np.ndarray, angle_rad: float) -> np.ndarray:
        axis = np.asarray(axis, dtype=np.float64)
        norm = float(np.linalg.norm(axis))
        if norm < 1e-12:
            return np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float64)
        axis = axis / norm
        s = np.sin(angle_rad / 2.0)
        return self._quat_normalize(np.array([np.cos(angle_rad / 2.0), axis[0] * s, axis[1] * s, axis[2] * s], dtype=np.float64))

    def _quat_to_matrix(self, q: np.ndarray) -> np.ndarray:
        return VideoVolume.quat_to_matrix(q)

    def _orbit_drag_to_quat(self, dx_px: float, dy_px: float) -> np.ndarray:
        base = 2.6 / max(240.0, float(min(self.width(), self.height())))
        yaw_angle = dx_px * base
        pitch_angle = dy_px * base

        q_yaw = self._quat_from_axis_angle(np.array([0.0, 0.0, 1.0], dtype=np.float64), yaw_angle)
        q_pitch = self._quat_from_axis_angle(np.array([1.0, 0.0, 0.0], dtype=np.float64), pitch_angle)
        return self._quat_normalize(self._quat_multiply(q_pitch, q_yaw))

    def _distance_to_segment(self, p: np.ndarray, a: np.ndarray, b: np.ndarray) -> tuple[float, float]:
        ab = b - a
        denom = float(np.dot(ab, ab))
        if denom < 1e-12:
            return float(np.linalg.norm(p - a)), 0.0
        t = float(np.dot(p - a, ab) / denom)
        t_clamped = max(0.0, min(1.0, t))
        proj = a + ab * t_clamped
        return float(np.linalg.norm(p - proj)), t_clamped

    def _axis_hit_test(self, pos: QPoint) -> str | None:
        if not self._axis_screen_cache:
            return None

        origin = np.asarray(self._axis_screen_cache.get("origin", [0.0, 0.0]), dtype=np.float64)
        axes = self._axis_screen_cache.get("axes", {})
        p = np.array([float(pos.x()), float(pos.y())], dtype=np.float64)

        best_name = None
        best_dist = 1e9
        for name, info in axes.items():
            end = np.asarray(info.get("end", [0.0, 0.0]), dtype=np.float64)
            seg_len = float(np.linalg.norm(end - origin))
            if seg_len < 8.0:
                continue
            dist, t = self._distance_to_segment(p, origin, end)
            end_dist = float(np.linalg.norm(p - end))
            threshold = max(8.0, min(14.0, seg_len * 0.16))
            if (0.08 <= t <= 1.05 and dist <= threshold) or end_dist <= threshold + 2.0:
                score = min(dist, end_dist * 0.8)
                if score < best_dist:
                    best_dist = score
                    best_name = str(name)
        return best_name

    def _axis_drag_angle(self, axis_name: str, dx_px: float, dy_px: float) -> float:
        if not self._axis_screen_cache or axis_name not in self._axis_screen_cache.get("axes", {}):
            return 0.0

        origin = np.asarray(self._axis_screen_cache["origin"], dtype=np.float64)
        end = np.asarray(self._axis_screen_cache["axes"][axis_name]["end"], dtype=np.float64)
        axis_dir = end - origin
        norm = float(np.linalg.norm(axis_dir))
        if norm < 1e-12:
            return 0.0
        axis_dir = axis_dir / norm
        perp = np.array([-axis_dir[1], axis_dir[0]], dtype=np.float64)
        motion = np.array([dx_px, dy_px], dtype=np.float64)
        amount = float(np.dot(motion, perp))
        base = 3.0 / max(240.0, float(min(self.width(), self.height())))
        return amount * base

    def _axis_local_vector(self, axis_name: str) -> np.ndarray | None:
        axis_local_map = {
            "X": np.array([1.0, 0.0, 0.0], dtype=np.float64),
            "Y": np.array([0.0, 0.0, 1.0], dtype=np.float64),
            "T": np.array([0.0, 1.0, 0.0], dtype=np.float64),
        }
        return axis_local_map.get(axis_name)

    def _apply_axis_rotation(self, axis_name: str, angle_rad: float):
        if abs(angle_rad) < 1e-9:
            return
        axis_local = self._axis_local_vector(axis_name)
        if axis_local is None:
            return
        q_axis = self._quat_from_axis_angle(axis_local, angle_rad)
        self.orientation = self._quat_normalize(self._quat_multiply(self.orientation, q_axis))

    def _apply_plane_axis_rotation(self, axis_name: str, angle_rad: float):
        if abs(angle_rad) < 1e-9:
            return
        axis_local = self._axis_local_vector(axis_name)
        if axis_local is None:
            return
        q_axis = self._quat_from_axis_angle(axis_local, angle_rad)
        self.plane_orientation = self._quat_normalize(self._quat_multiply(q_axis, self.plane_orientation))

    def set_volume(self, volume: np.ndarray | None, alpha_volume: np.ndarray | None = None):
        self.volume = volume
        self.alpha_volume = alpha_volume
        self.face_images = {}
        self.face_alpha_images = {}
        self.volume_slice_cache = {}

        if volume is None:
            self.dims_xyz = (1, 1, 1)
            self.update()
            return

        y_size, z_size, x_size = volume.shape[:3]
        self.dims_xyz = (x_size, y_size, z_size)
        self.face_images = self._build_face_images(volume)
        if alpha_volume is not None and np.any(alpha_volume < 250):
            self.volume_slice_cache = self._build_volume_slice_cache(volume, alpha_volume)
        self.update()

    def set_alpha_enabled(self, enabled: bool):
        self.alpha_enabled = bool(enabled)
        self.update()

    def reset_camera(self):
        self.orientation = self._default_orientation()
        self.zoom = 1.0
        self._drag_mode = None
        self._active_axis = None
        self.update()

    def reset_reference_plane(self):
        self.plane_orientation = np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float64)
        self.update()
        self.referencePlaneChanged.emit()

    def get_reference_plane_quaternion(self) -> np.ndarray:
        return self.plane_orientation.copy()

    def get_reference_plane_axes(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        rot = self._quat_to_matrix(self.plane_orientation).astype(np.float32)
        basis = np.array(
            [
                [1.0, 0.0, 0.0],
                [0.0, 0.0, 1.0],
                [0.0, 1.0, 0.0],
            ],
            dtype=np.float32,
        )
        u_vec, v_vec, n_vec = basis @ rot.T
        return u_vec, v_vec, n_vec

    def _resize_face(self, img: np.ndarray, max_side: int) -> np.ndarray:
        h, w = img.shape[:2]
        longest = max(h, w)
        if longest <= max_side:
            return img
        scale = max_side / float(longest)
        new_w = max(1, int(round(w * scale)))
        new_h = max(1, int(round(h * scale)))
        return cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_AREA)

    def _alpha_composite_projection(
        self,
        rgb_volume: np.ndarray,
        alpha_volume: np.ndarray,
        axis: int,
        reverse: bool = False,
    ) -> tuple[np.ndarray, np.ndarray]:
        """
        将 volume[y, z, x, 3] 与 alpha[y, z, x] 沿指定轴做前向 alpha 合成投影。
        返回:
            out_rgb   : [h, w, 3], uint8
            out_alpha : [h, w], uint8
        """
        rgb = rgb_volume.astype(np.float32) / 255.0
        alpha = alpha_volume.astype(np.float32) / 255.0

        if reverse:
            rgb = np.flip(rgb, axis=axis)
            alpha = np.flip(alpha, axis=axis)

        rgb = np.moveaxis(rgb, axis, 0)      # [depth, h, w, 3]
        alpha = np.moveaxis(alpha, axis, 0)  # [depth, h, w]

        h, w = alpha.shape[1], alpha.shape[2]
        out_rgb = np.zeros((h, w, 3), dtype=np.float32)
        out_alpha = np.zeros((h, w), dtype=np.float32)

        for i in range(alpha.shape[0]):
            ai = alpha[i]
            ci = rgb[i]
            contrib = ai * (1.0 - out_alpha)
            out_rgb += ci * contrib[..., None]
            out_alpha += contrib

        out_rgb = np.clip(out_rgb * 255.0, 0.0, 255.0).astype(np.uint8)
        out_alpha = np.clip(out_alpha * 255.0, 0.0, 255.0).astype(np.uint8)
        return out_rgb, out_alpha

    def _build_face_images(self, volume: np.ndarray) -> dict[str, np.ndarray]:
        faces: dict[str, np.ndarray] = {}
        self.face_alpha_images = {}

        alpha_volume = self.alpha_volume
        use_projection = (
            alpha_volume is not None
            and np.any(alpha_volume < 250)
        )

        if use_projection:
            img, a = self._alpha_composite_projection(volume, alpha_volume, axis=0, reverse=False)
            faces["front"] = img
            self.face_alpha_images["front"] = a

            img, a = self._alpha_composite_projection(volume, alpha_volume, axis=0, reverse=True)
            faces["back"] = img
            self.face_alpha_images["back"] = a

            img, a = self._alpha_composite_projection(volume, alpha_volume, axis=2, reverse=False)
            faces["left"] = np.transpose(img, (1, 0, 2)).copy()
            self.face_alpha_images["left"] = np.transpose(a, (1, 0)).copy()

            img, a = self._alpha_composite_projection(volume, alpha_volume, axis=2, reverse=True)
            faces["right"] = np.transpose(img, (1, 0, 2)).copy()
            self.face_alpha_images["right"] = np.transpose(a, (1, 0)).copy()

            img, a = self._alpha_composite_projection(volume, alpha_volume, axis=1, reverse=False)
            faces["bottom"] = img
            self.face_alpha_images["bottom"] = a

            img, a = self._alpha_composite_projection(volume, alpha_volume, axis=1, reverse=True)
            faces["top"] = img
            self.face_alpha_images["top"] = a
        else:
            faces["front"] = volume[0, :, :, :].copy()
            faces["back"] = volume[-1, :, :, :].copy()
            faces["left"] = np.transpose(volume[:, :, 0, :], (1, 0, 2)).copy()
            faces["right"] = np.transpose(volume[:, :, -1, :], (1, 0, 2)).copy()
            faces["bottom"] = volume[:, 0, :, :].copy()
            faces["top"] = volume[:, -1, :, :].copy()

            if alpha_volume is not None:
                self.face_alpha_images["front"] = alpha_volume[0, :, :].copy()
                self.face_alpha_images["back"] = alpha_volume[-1, :, :].copy()
                self.face_alpha_images["left"] = np.transpose(alpha_volume[:, :, 0], (1, 0)).copy()
                self.face_alpha_images["right"] = np.transpose(alpha_volume[:, :, -1], (1, 0)).copy()
                self.face_alpha_images["bottom"] = alpha_volume[:, 0, :].copy()
                self.face_alpha_images["top"] = alpha_volume[:, -1, :].copy()

        for key, img in list(faces.items()):
            faces[key] = self._resize_face(img, self.preview_face_limit)

        for key, img in list(self.face_alpha_images.items()):
            self.face_alpha_images[key] = self._resize_face(img, self.preview_face_limit)

        return faces

    def _build_face_alpha_images(self, alpha_volume: np.ndarray) -> dict[str, np.ndarray]:
        # 兼容旧接口，实际已经在 _build_face_images 中一并生成。
        faces: dict[str, np.ndarray] = {}
        faces["front"] = alpha_volume[0, :, :].copy()
        faces["back"] = alpha_volume[-1, :, :].copy()
        faces["left"] = np.transpose(alpha_volume[:, :, 0], (1, 0)).copy()
        faces["right"] = np.transpose(alpha_volume[:, :, -1], (1, 0)).copy()
        faces["bottom"] = alpha_volume[:, 0, :].copy()
        faces["top"] = alpha_volume[:, -1, :].copy()

        for key, img in list(faces.items()):
            faces[key] = self._resize_face(img, self.preview_face_limit)

        return faces


    def _build_volume_slice_cache(self, volume: np.ndarray, alpha_volume: np.ndarray) -> dict[str, list[dict[str, object]]]:
        cache: dict[str, list[dict[str, object]]] = {}
        x_size = volume.shape[2]
        t_size = volume.shape[0]
        z_size = volume.shape[1]
        longest = max(x_size, t_size, z_size, 1)

        def choose_indices(size: int) -> list[int]:
            target = 40
            count = int(round(target * size / longest))
            count = max(12, min(size, count))
            if count >= size:
                return list(range(size))
            vals = np.linspace(0, size - 1, count)
            idxs = np.unique(np.round(vals).astype(int))
            return [int(v) for v in idxs.tolist()]

        t_slices: list[dict[str, object]] = []
        for idx in choose_indices(t_size):
            img = self._resize_face(volume[idx, :, :, :].copy(), self.preview_face_limit)
            a = self._resize_face(alpha_volume[idx, :, :].copy(), self.preview_face_limit)
            frac = 0.0 if t_size <= 1 else (float(idx) / float(t_size - 1))
            y_const = -1.0 + 2.0 * frac
            corners = np.array(
                [
                    [-1.0, y_const,  1.0],
                    [ 1.0, y_const,  1.0],
                    [ 1.0, y_const, -1.0],
                    [-1.0, y_const, -1.0],
                ],
                dtype=np.float32,
            )
            t_slices.append({"img": img, "alpha": a, "corners": corners, "frac": frac})
        cache["t"] = t_slices

        z_slices: list[dict[str, object]] = []
        for idx in choose_indices(z_size):
            img = self._resize_face(volume[:, idx, :, :].copy(), self.preview_face_limit)
            a = self._resize_face(alpha_volume[:, idx, :].copy(), self.preview_face_limit)
            frac = 0.0 if z_size <= 1 else (float(idx) / float(z_size - 1))
            z_const = -1.0 + 2.0 * frac
            corners = np.array(
                [
                    [-1.0, -1.0, z_const],
                    [ 1.0, -1.0, z_const],
                    [ 1.0,  1.0, z_const],
                    [-1.0,  1.0, z_const],
                ],
                dtype=np.float32,
            )
            z_slices.append({"img": img, "alpha": a, "corners": corners, "frac": frac})
        cache["z"] = z_slices

        x_slices: list[dict[str, object]] = []
        for idx in choose_indices(x_size):
            img = self._resize_face(np.transpose(volume[:, :, idx, :], (1, 0, 2)).copy(), self.preview_face_limit)
            a = self._resize_face(np.transpose(alpha_volume[:, :, idx], (1, 0)).copy(), self.preview_face_limit)
            frac = 0.0 if x_size <= 1 else (float(idx) / float(x_size - 1))
            x_const = -1.0 + 2.0 * frac
            corners = np.array(
                [
                    [x_const, -1.0,  1.0],
                    [x_const,  1.0,  1.0],
                    [x_const,  1.0, -1.0],
                    [x_const, -1.0, -1.0],
                ],
                dtype=np.float32,
            )
            x_slices.append({"img": img, "alpha": a, "corners": corners, "frac": frac})
        cache["x"] = x_slices
        return cache

    def _get_volume_render_axis(self) -> tuple[str, bool]:
        rot = self._quat_to_matrix(self.orientation).astype(np.float32)
        view_dir = rot.T @ np.array([0.0, 1.0, 0.0], dtype=np.float32)
        comps = {
            "x": float(view_dir[0]),
            "t": float(view_dir[1]),
            "z": float(view_dir[2]),
        }
        axis_name = max(comps.keys(), key=lambda k: abs(comps[k]))
        back_to_front_reverse = comps[axis_name] > 0.0
        return axis_name, back_to_front_reverse

    def _render_volume_slices(self, canvas: np.ndarray, canvas_w: int, canvas_h: int):
        if not self.alpha_enabled or self.alpha_volume is None or not self.volume_slice_cache:
            return

        axis_name, reverse = self._get_volume_render_axis()
        slices = self.volume_slice_cache.get(axis_name, [])
        if not slices:
            return

        order = list(reversed(slices)) if reverse else list(slices)
        n_slices = max(1, len(order))
        alpha_gain = min(0.72, max(0.16, 10.0 / float(n_slices)))
        dim_scale = max(self.dims_xyz[0], self.dims_xyz[1], self.dims_xyz[2], 1)

        for entry in order:
            img = entry["img"]
            alpha_src = entry["alpha"]
            corners_norm = np.asarray(entry["corners"], dtype=np.float32).copy()
            corners = corners_norm.copy()
            corners[:, 0] *= float(self.dims_xyz[0]) / float(dim_scale)
            corners[:, 1] *= float(self.dims_xyz[1]) / float(dim_scale)
            corners[:, 2] *= float(self.dims_xyz[2]) / float(dim_scale)

            quad, rotated = self._project_points(corners, canvas_w, canvas_h)
            edge1 = rotated[1] - rotated[0]
            edge2 = rotated[3] - rotated[0]
            normal = np.cross(edge1, edge2)
            face_strength = abs(float(normal[1]))
            if face_strength < 0.015:
                continue

            h, w = img.shape[:2]
            src = np.array([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]], dtype=np.float32)
            dst = quad.astype(np.float32)
            matrix = cv2.getPerspectiveTransform(src, dst)

            warped = cv2.warpPerspective(
                img,
                matrix,
                (canvas_w, canvas_h),
                flags=cv2.INTER_LINEAR,
                borderMode=cv2.BORDER_CONSTANT,
                borderValue=(0, 0, 0),
            )
            mask = cv2.warpPerspective(
                alpha_src,
                matrix,
                (canvas_w, canvas_h),
                flags=cv2.INTER_LINEAR,
                borderMode=cv2.BORDER_CONSTANT,
                borderValue=0,
            )
            if not np.any(mask):
                continue

            local_gain = alpha_gain * (0.45 + 0.55 * min(1.0, face_strength * 2.0))
            mask_float = ((mask.astype(np.float32) / 255.0) * local_gain)[..., None]
            canvas[:] = (
                canvas.astype(np.float32) * (1.0 - mask_float)
                + warped.astype(np.float32) * mask_float
            ).astype(np.uint8)

        cv2.putText(
            canvas,
            f"Volume render axis={axis_name.upper()}  slices={n_slices}",
            (16, 124),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (220, 230, 240),
            1,
            cv2.LINE_AA,
        )

    def _rotate_points(self, points: np.ndarray) -> np.ndarray:
        rot = self._quat_to_matrix(self.orientation).astype(np.float32)
        return points @ rot.T

    def _project_points(self, points: np.ndarray, canvas_w: int, canvas_h: int) -> tuple[np.ndarray, np.ndarray]:
        rotated = self._rotate_points(points)
        depth = rotated[:, 1] + self.camera_distance
        depth = np.clip(depth, 0.25, None)

        scale = min(canvas_w, canvas_h) * 0.72 * self.zoom
        screen_x = rotated[:, 0] * scale / depth + canvas_w / 2.0
        screen_y = -rotated[:, 2] * scale / depth + canvas_h / 2.0
        projected = np.stack([screen_x, screen_y], axis=1).astype(np.float32)
        return projected, rotated

    def _draw_reference_plane(self, canvas: np.ndarray, vertices: np.ndarray, canvas_w: int, canvas_h: int):
        u_vec, v_vec, n_vec = self.get_reference_plane_axes()
        proj_u = vertices @ u_vec
        proj_v = vertices @ v_vec
        u_extent = float(np.max(np.abs(proj_u)))
        v_extent = float(np.max(np.abs(proj_v)))
        u_extent = max(u_extent, 0.25)
        v_extent = max(v_extent, 0.25)

        plane_pts = np.array(
            [
                -u_vec * u_extent + v_vec * v_extent,
                u_vec * u_extent + v_vec * v_extent,
                u_vec * u_extent - v_vec * v_extent,
                -u_vec * u_extent - v_vec * v_extent,
            ],
            dtype=np.float32,
        )
        plane_proj, plane_rot = self._project_points(plane_pts, canvas_w, canvas_h)
        poly = np.round(plane_proj).astype(np.int32).reshape((-1, 1, 2))

        overlay = canvas.copy()
        cv2.fillConvexPoly(overlay, poly, (70, 180, 255), cv2.LINE_AA)
        cv2.addWeighted(overlay, 0.18, canvas, 0.82, 0.0, dst=canvas)
        cv2.polylines(canvas, [poly], True, (110, 220, 255), 2, cv2.LINE_AA)

        center = np.array([[0.0, 0.0, 0.0]], dtype=np.float32)
        arrow_len = 0.55 * max(self.dims_xyz[0], self.dims_xyz[1], self.dims_xyz[2]) / max(1.0, float(max(self.dims_xyz)))
        arrow_pts = np.vstack([center, n_vec[None, :] * arrow_len])
        arrow_proj, _ = self._project_points(arrow_pts, canvas_w, canvas_h)
        p0 = tuple(np.round(arrow_proj[0]).astype(int))
        p1 = tuple(np.round(arrow_proj[1]).astype(int))
        cv2.arrowedLine(canvas, p0, p1, (0, 220, 255), 2, cv2.LINE_AA, tipLength=0.18)
        cv2.putText(canvas, "N", (p1[0] + 8, p1[1] - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 240, 255), 2, cv2.LINE_AA)

        center_2d = np.mean(plane_proj, axis=0)
        cv2.putText(
            canvas,
            "Reference Plane",
            (int(center_2d[0]) - 70, int(center_2d[1]) - 8),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (140, 235, 255),
            1,
            cv2.LINE_AA,
        )

    def _render_cube_image(self, canvas_w: int, canvas_h: int) -> np.ndarray:
        canvas = np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)
        canvas[:, :] = (18, 18, 18)
        self._axis_screen_cache = {}

        if self.volume is None or not self.face_images:
            return canvas

        x_size, y_size, z_size = self.dims_xyz
        max_dim = float(max(x_size, y_size, z_size, 1))
        dx = x_size / max_dim
        dy = y_size / max_dim
        dz = z_size / max_dim

        vertices = np.array(
            [
                [-dx, -dy, -dz],
                [ dx, -dy, -dz],
                [ dx,  dy, -dz],
                [-dx,  dy, -dz],
                [-dx, -dy,  dz],
                [ dx, -dy,  dz],
                [ dx,  dy,  dz],
                [-dx,  dy,  dz],
            ],
            dtype=np.float32,
        )

        faces = [
            {"name": "front",  "geom": [0, 1, 5, 4], "tex": [4, 5, 1, 0], "label": "T-"},
            {"name": "back",   "geom": [3, 2, 6, 7], "tex": [7, 6, 2, 3], "label": "T+"},
            {"name": "left",   "geom": [0, 4, 7, 3], "tex": [4, 7, 3, 0], "label": "X-"},
            {"name": "right",  "geom": [1, 2, 6, 5], "tex": [6, 5, 1, 2], "label": "X+"},
            {"name": "bottom", "geom": [0, 3, 2, 1], "tex": [0, 1, 2, 3], "label": "Y-"},
            {"name": "top",    "geom": [4, 5, 6, 7], "tex": [4, 5, 6, 7], "label": "Y+"},
        ]

        projected, rotated = self._project_points(vertices, canvas_w, canvas_h)
        use_volume_render = self.alpha_enabled and self.alpha_volume is not None and bool(self.volume_slice_cache)

        if use_volume_render:
            self._render_volume_slices(canvas, canvas_w, canvas_h)
        else:
            rendered_faces = []

            for face in faces:
                geom_idxs = face["geom"]
                pts3 = rotated[geom_idxs]
                v1 = pts3[1] - pts3[0]
                v2 = pts3[2] - pts3[0]
                normal = np.cross(v1, v2)

                quad_geom = projected[geom_idxs]
                quad_tex = projected[face["tex"]]
                avg_depth = float(np.mean(pts3[:, 1]))
                center = np.mean(quad_geom, axis=0)
                front_facing = bool(normal[1] < 0)
                rendered_faces.append((avg_depth, face["name"], quad_tex, center, face["label"], front_facing))

            rendered_faces.sort(key=lambda item: item[0], reverse=True)

            for _, face_name, quad, center, face_label, front_facing in rendered_faces:
                img = self.face_images.get(face_name)
                if img is None:
                    continue

                h, w = img.shape[:2]
                src = np.array([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]], dtype=np.float32)
                dst = quad.astype(np.float32)

                matrix = cv2.getPerspectiveTransform(src, dst)
                warped = cv2.warpPerspective(
                    img,
                    matrix,
                    (canvas_w, canvas_h),
                    flags=cv2.INTER_LINEAR,
                    borderMode=cv2.BORDER_CONSTANT,
                    borderValue=(0, 0, 0),
                )

                if self.alpha_enabled and face_name in self.face_alpha_images:
                    alpha_src = self.face_alpha_images[face_name]
                else:
                    alpha_src = np.full((h, w), 255, dtype=np.uint8)

                mask = cv2.warpPerspective(
                    alpha_src,
                    matrix,
                    (canvas_w, canvas_h),
                    flags=cv2.INTER_LINEAR,
                    borderMode=cv2.BORDER_CONSTANT,
                    borderValue=0,
                )

                if not front_facing:
                    warped = (warped.astype(np.float32) * 0.52).astype(np.uint8)
                    alpha = 0.42
                    edge_color = (140, 170, 210)
                    text_color = (180, 210, 240)
                else:
                    alpha = 0.96
                    edge_color = (235, 235, 235)
                    text_color = (255, 255, 255)

                mask_float = ((mask.astype(np.float32) / 255.0) * alpha)[..., None]
                canvas = (canvas.astype(np.float32) * (1.0 - mask_float) + warped.astype(np.float32) * mask_float).astype(np.uint8)

                poly = np.round(quad).astype(np.int32).reshape((-1, 1, 2))
                cv2.polylines(canvas, [poly], True, edge_color, 1, cv2.LINE_AA)
                text_pos = (int(center[0]) - 18, int(center[1]))
                cv2.putText(canvas, face_label, text_pos, cv2.FONT_HERSHEY_SIMPLEX, 0.55, text_color, 1, cv2.LINE_AA)

        self._draw_reference_plane(canvas, vertices, canvas_w, canvas_h)

        cube_edges = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]
        for a, b in cube_edges:
            p1 = tuple(np.round(projected[a]).astype(int))
            p2 = tuple(np.round(projected[b]).astype(int))
            cv2.line(canvas, p1, p2, (255, 255, 255), 1, cv2.LINE_AA)

        axis_points = np.array(
            [
                [0.0, 0.0, 0.0],
                [dx * 1.28, 0.0, 0.0],
                [0.0, 0.0, dz * 1.28],
                [0.0, dy * 1.28, 0.0],
            ],
            dtype=np.float32,
        )
        axis_proj, _ = self._project_points(axis_points, canvas_w, canvas_h)
        axis_origin_xy = axis_proj[0].astype(np.float32)
        axis_origin = tuple(np.round(axis_origin_xy).astype(int))
        axis_specs = [
            (1, "X", (255, 120, 120)),
            (2, "Y", (120, 255, 160)),
            (3, "T", (120, 180, 255)),
        ]
        self._axis_screen_cache = {"origin": axis_origin_xy.copy(), "axes": {}}
        cv2.circle(canvas, axis_origin, 4, (245, 245, 245), -1, cv2.LINE_AA)
        for idx, name, color in axis_specs:
            end_xy = axis_proj[idx].astype(np.float32)
            end = tuple(np.round(end_xy).astype(int))
            self._axis_screen_cache["axes"][name] = {"end": end_xy.copy(), "color": color}

            is_active = (name == self._active_axis)
            is_hover = (name == self._hover_axis)
            line_thickness = 4 if is_active else (3 if is_hover else 2)
            point_radius = 7 if is_active else (6 if is_hover else 5)
            draw_color = tuple(int(c) for c in color)
            if is_active:
                draw_color = tuple(min(255, c + 25) for c in draw_color)
            elif is_hover:
                draw_color = tuple(min(255, c + 12) for c in draw_color)

            cv2.line(canvas, axis_origin, end, draw_color, line_thickness, cv2.LINE_AA)
            cv2.circle(canvas, end, point_radius, draw_color, -1, cv2.LINE_AA)
            cv2.putText(canvas, name, (end[0] + 8, end[1] - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.65, draw_color, 2, cv2.LINE_AA)

        cv2.putText(canvas, "3D Cube + Reference Plane", (16, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (235, 235, 235), 2, cv2.LINE_AA)
        cv2.putText(
            canvas,
            "Middle: orbit  Left on axis: rotate view around axis  Right: rotate reference plane",
            (16, 54),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.50,
            (210, 210, 210),
            1,
            cv2.LINE_AA,
        )
        cv2.putText(
            canvas,
            "Hold Q/W/E + Right Drag: rotate reference plane around X/Y/T   Wheel: zoom   R: reset view   Shift+R: reset plane",
            (16, 76),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.50,
            (210, 210, 210),
            1,
            cv2.LINE_AA,
        )
        axis_lock_text = self._plane_axis_lock if self._plane_axis_lock is not None else "free"
        alpha_text = "on" if self.alpha_enabled else "off"
        has_alpha_text = "yes" if self.face_alpha_images else "no"
        volume_text = "volume" if (self.alpha_enabled and self.alpha_volume is not None and bool(self.volume_slice_cache)) else "faces"
        cv2.putText(canvas, f"x={x_size}  y={z_size}  t={y_size}   plane_lock={axis_lock_text}   alpha={alpha_text}   has_alpha={has_alpha_text}   mode={volume_text}", (16, 102), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (210, 210, 210), 1, cv2.LINE_AA)
        return canvas

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, True)
        painter.fillRect(self.rect(), Qt.GlobalColor.black)

        if self.volume is None:
            painter.setPen(Qt.GlobalColor.lightGray)
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, "请先导入视频后查看 3D 立方体")
            return

        w = max(1, self.width())
        h = max(1, self.height())
        canvas = self._render_cube_image(w, h)
        canvas = np.ascontiguousarray(canvas)
        image = QImage(canvas.data, w, h, w * 3, QImage.Format.Format_RGB888).copy()
        painter.drawImage(self.rect(), image)

    def mousePressEvent(self, event):
        self.setFocus(Qt.FocusReason.MouseFocusReason)
        pos = event.position().toPoint()
        if event.button() == Qt.MouseButton.LeftButton:
            axis_name = self._axis_hit_test(pos)
            if axis_name is not None:
                self._drag_mode = "axis"
                self._active_axis = axis_name
                self._last_pos = pos
                self.setCursor(Qt.CursorShape.ClosedHandCursor)
                self.update()
                event.accept()
                return

        if event.button() == Qt.MouseButton.MiddleButton:
            self._drag_mode = "orbit"
            self._active_axis = None
            self._last_pos = pos
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
            self.update()
            event.accept()
            return

        if event.button() == Qt.MouseButton.RightButton:
            self._drag_mode = "plane"
            self._active_axis = None
            self._last_pos = pos
            self.setCursor(Qt.CursorShape.SizeAllCursor)
            self.update()
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        pos = event.position().toPoint()
        if self._drag_mode == "orbit":
            dx = float(pos.x() - self._last_pos.x())
            dy = float(pos.y() - self._last_pos.y())
            q_drag = self._orbit_drag_to_quat(dx, dy)
            self.orientation = self._quat_normalize(self._quat_multiply(q_drag, self.orientation))
            self._last_pos = pos
            self.update()
            event.accept()
            return

        if self._drag_mode == "plane":
            dx = float(pos.x() - self._last_pos.x())
            dy = float(pos.y() - self._last_pos.y())
            if self._plane_axis_lock is not None:
                angle = self._axis_drag_angle(self._plane_axis_lock, dx, dy)
                if abs(angle) < 1e-9:
                    angle = (dx + dy) * (2.0 / max(240.0, float(min(self.width(), self.height()))))
                self._apply_plane_axis_rotation(self._plane_axis_lock, angle)
            else:
                q_drag = self._orbit_drag_to_quat(dx, dy)
                self.plane_orientation = self._quat_normalize(self._quat_multiply(q_drag, self.plane_orientation))
            self._last_pos = pos
            self.update()
            event.accept()
            return

        if self._drag_mode == "axis" and self._active_axis is not None:
            dx = float(pos.x() - self._last_pos.x())
            dy = float(pos.y() - self._last_pos.y())
            angle = self._axis_drag_angle(self._active_axis, dx, dy)
            self._apply_axis_rotation(self._active_axis, angle)
            self._last_pos = pos
            self.update()
            event.accept()
            return

        hover_axis = self._axis_hit_test(pos)
        if hover_axis != self._hover_axis:
            self._hover_axis = hover_axis
            if hover_axis is not None:
                self.setCursor(Qt.CursorShape.OpenHandCursor)
            else:
                self.unsetCursor()
            self.update()
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        plane_changed = (self._drag_mode == "plane")
        if event.button() in (Qt.MouseButton.LeftButton, Qt.MouseButton.MiddleButton, Qt.MouseButton.RightButton):
            changed = (self._drag_mode is not None or self._active_axis is not None)
            self._drag_mode = None
            self._active_axis = None
            hover_axis = self._axis_hit_test(event.position().toPoint())
            self._hover_axis = hover_axis
            if hover_axis is not None:
                self.setCursor(Qt.CursorShape.OpenHandCursor)
            else:
                self.unsetCursor()
            if changed:
                self.update()
            event.accept()
            if plane_changed:
                self.referencePlaneChanged.emit()
            return
        super().mouseReleaseEvent(event)

    def wheelEvent(self, event):
        delta = event.angleDelta().y()
        if delta != 0:
            factor = 1.0 + (0.08 if delta > 0 else -0.08)
            self.zoom *= factor
            self.zoom = max(0.45, min(2.2, self.zoom))
            self.update()
            event.accept()
            return
        super().wheelEvent(event)

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Q:
            self._plane_axis_lock = "X"
            self.update()
            event.accept()
            return
        if event.key() == Qt.Key.Key_W:
            self._plane_axis_lock = "Y"
            self.update()
            event.accept()
            return
        if event.key() == Qt.Key.Key_E:
            self._plane_axis_lock = "T"
            self.update()
            event.accept()
            return
        if event.key() == Qt.Key.Key_R and (event.modifiers() & Qt.KeyboardModifier.ShiftModifier):
            self.reset_reference_plane()
            event.accept()
            return
        if event.key() == Qt.Key.Key_R:
            self.reset_camera()
            event.accept()
            return
        super().keyPressEvent(event)

    def keyReleaseEvent(self, event):
        if event.key() == Qt.Key.Key_Q and self._plane_axis_lock == "X":
            self._plane_axis_lock = None
            self.update()
            event.accept()
            return
        if event.key() == Qt.Key.Key_W and self._plane_axis_lock == "Y":
            self._plane_axis_lock = None
            self.update()
            event.accept()
            return
        if event.key() == Qt.Key.Key_E and self._plane_axis_lock == "T":
            self._plane_axis_lock = None
            self.update()
            event.accept()
            return
        super().keyReleaseEvent(event)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("ChronoVolume-原型程序")
        self.resize(1480, 920)

        self.video = VideoVolume()
        self.view: np.ndarray | None = None  # [v, h, t, c]
        self.alpha_view: np.ndarray | None = None  # [v, h, t]
        self.current_index = 0
        self.current_view_source = "axis"
        self.oblique_info: dict | None = None
        self._auto_refreshing_plane = False

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.next_frame)

        self._build_ui()
        self._build_menu()
        self.update_timer_interval()
        self.update_info_panel()

    def _build_ui(self):
        self.preview_label = QLabel("请先导入视频")
        self.preview_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.preview_label.setMinimumSize(QSize(720, 520))
        self.preview_label.setStyleSheet(
            """
            QLabel {
                background: #111111;
                color: #dddddd;
                border: 1px solid #2a2a2a;
                font-size: 18px;
            }
            """
        )

        self.cube_view = CubeViewWidget()
        self.cube_view.referencePlaneChanged.connect(self.on_reference_plane_changed)

        self.frame_text_label = QLabel("当前索引：- / -")
        self.frame_text_label.setAlignment(Qt.AlignmentFlag.AlignCenter)

        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(0, 0)
        self.slider.setEnabled(False)
        self.slider.sliderMoved.connect(self.on_slider_moved)

        self.open_btn = QPushButton("导入视频")
        self.open_btn.clicked.connect(self.open_video)

        self.play_btn = QPushButton("播放")
        self.play_btn.setEnabled(False)
        self.play_btn.clicked.connect(self.toggle_play)

        self.stop_btn = QPushButton("停止")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self.stop_and_reset)

        self.export_btn = QPushButton("导出当前模式为 MP4")
        self.export_btn.setEnabled(False)
        self.export_btn.clicked.connect(self.export_current_view)

        self.apply_plane_btn = QPushButton("以参考面生成 2D 切片视图")
        self.apply_plane_btn.setEnabled(False)
        self.apply_plane_btn.clicked.connect(self.apply_reference_plane_view)

        self.restore_axis_btn = QPushButton("恢复轴模式视图")
        self.restore_axis_btn.setEnabled(False)
        self.restore_axis_btn.clicked.connect(self.rebuild_view)

        self.reset_3d_btn = QPushButton("重置 3D 视角")
        self.reset_3d_btn.setEnabled(False)
        self.reset_3d_btn.clicked.connect(self.cube_view.reset_camera)

        self.reset_plane_btn = QPushButton("重置参考面")
        self.reset_plane_btn.setEnabled(False)
        self.reset_plane_btn.clicked.connect(self.cube_view.reset_reference_plane)

        self.mode_combo = QComboBox()
        for time_axis, h_axis, v_axis in MODES:
            self.mode_combo.addItem(f"时间轴={time_axis} | 横轴={h_axis} | 纵轴={v_axis}", (time_axis, h_axis, v_axis))
        self.mode_combo.setEnabled(False)
        self.mode_combo.currentIndexChanged.connect(self.rebuild_view)

        self.play_fps_box = QDoubleSpinBox()
        self.play_fps_box.setRange(1.0, 120.0)
        self.play_fps_box.setValue(25.0)
        self.play_fps_box.setSingleStep(1.0)
        self.play_fps_box.setSuffix(" fps")
        self.play_fps_box.valueChanged.connect(self.update_timer_interval)

        self.export_fps_box = QDoubleSpinBox()
        self.export_fps_box.setRange(1.0, 120.0)
        self.export_fps_box.setValue(25.0)
        self.export_fps_box.setSingleStep(1.0)
        self.export_fps_box.setSuffix(" fps")

        self.max_side_box = QSpinBox()
        self.max_side_box.setRange(240, 4096)
        self.max_side_box.setValue(960)
        self.max_side_box.setSingleStep(120)
        self.max_side_box.setSuffix(" px")

        self.alpha_checkbox = QCheckBox("识别 Alpha 通道（3D/2D）")
        self.alpha_checkbox.setChecked(True)
        self.alpha_checkbox.setEnabled(False)
        self.alpha_checkbox.toggled.connect(self.on_alpha_checkbox_toggled)

        self.path_value = QLabel("-")
        self.path_value.setWordWrap(True)
        self.origin_value = QLabel("-")
        self.loaded_value = QLabel("-")
        self.volume_value = QLabel("-")
        self.view_value = QLabel("-")
        self.memory_value = QLabel("-")
        self.alpha_value = QLabel("-")
        self.alpha_value.setWordWrap(True)
        self.source_value = QLabel("-")
        self.plane_value = QLabel("-")
        self.plane_value.setWordWrap(True)

        control_box = QGroupBox("控制")
        control_layout = QVBoxLayout()
        control_layout.addWidget(self.open_btn)
        control_layout.addWidget(self.play_btn)
        control_layout.addWidget(self.stop_btn)
        control_layout.addWidget(self.export_btn)
        control_layout.addWidget(self.apply_plane_btn)
        control_layout.addWidget(self.restore_axis_btn)
        control_layout.addWidget(self.reset_3d_btn)
        control_layout.addWidget(self.reset_plane_btn)
        control_layout.addSpacing(8)
        control_layout.addWidget(QLabel("轴模式"))
        control_layout.addWidget(self.mode_combo)
        control_layout.addWidget(QLabel("预览播放速度"))
        control_layout.addWidget(self.play_fps_box)
        control_layout.addWidget(QLabel("导出帧率"))
        control_layout.addWidget(self.export_fps_box)
        control_layout.addWidget(QLabel("导入最长边限制"))
        control_layout.addWidget(self.max_side_box)
        control_layout.addWidget(self.alpha_checkbox)
        control_layout.addStretch(1)
        control_box.setLayout(control_layout)

        info_box = QGroupBox("信息")
        info_form = QFormLayout()
        info_form.addRow("文件", self.path_value)
        info_form.addRow("原视频尺寸", self.origin_value)
        info_form.addRow("载入后尺寸", self.loaded_value)
        info_form.addRow("原始体数据", self.volume_value)
        info_form.addRow("当前视图", self.view_value)
        info_form.addRow("当前来源", self.source_value)
        info_form.addRow("Alpha", self.alpha_value)
        info_form.addRow("参考面", self.plane_value)
        info_form.addRow("内存占用", self.memory_value)
        info_box.setLayout(info_form)

        left_layout = QVBoxLayout()
        left_layout.addWidget(control_box)
        left_layout.addWidget(info_box)
        left_layout.addStretch(1)

        left_panel = QWidget()
        left_panel.setLayout(left_layout)
        left_panel.setMaximumWidth(390)

        preview_page = QWidget()
        preview_layout = QVBoxLayout()
        preview_layout.addWidget(self.preview_label, 1)
        preview_layout.addWidget(self.frame_text_label)
        preview_layout.addWidget(self.slider)
        preview_page.setLayout(preview_layout)

        cube_page = QWidget()
        cube_layout = QVBoxLayout()
        cube_hint = QLabel(
            "3D 视图：中键拖动=旋转观察视角；左键按住 X / Y / T 轴=绕对应轴转；右键拖动=自由旋转参考面；滚轮=缩放。"
            "当你点击“以参考面生成 2D 切片视图”后，2D 预览与播放将沿参考面法向做平行切片。"
            "如果当前就在参考面切片模式下，右键释放后会自动刷新。"
        )
        cube_hint.setWordWrap(True)
        cube_layout.addWidget(self.cube_view, 1)
        cube_layout.addWidget(cube_hint)
        cube_page.setLayout(cube_layout)

        self.tab_widget = QTabWidget()
        self.tab_widget.addTab(preview_page, "2D 播放视图")
        self.tab_widget.addTab(cube_page, "3D 立方体视图")

        right_layout = QVBoxLayout()
        right_layout.addWidget(self.tab_widget, 1)

        right_panel = QWidget()
        right_panel.setLayout(right_layout)

        root_layout = QHBoxLayout()
        root_layout.addWidget(left_panel)
        root_layout.addWidget(right_panel, 1)

        central = QWidget()
        central.setLayout(root_layout)
        self.setCentralWidget(central)

        self.setStatusBar(QStatusBar())
        self.statusBar().showMessage("就绪")

    def _build_menu(self):
        file_menu = self.menuBar().addMenu("文件")

        open_action = QAction("打开视频", self)
        open_action.setShortcut(QKeySequence.StandardKey.Open)
        open_action.triggered.connect(self.open_video)
        file_menu.addAction(open_action)

        export_action = QAction("导出当前模式", self)
        export_action.setShortcut("Ctrl+E")
        export_action.triggered.connect(self.export_current_view)
        file_menu.addAction(export_action)

        plane_action = QAction("按参考面生成切片视图", self)
        plane_action.setShortcut("Ctrl+P")
        plane_action.triggered.connect(self.apply_reference_plane_view)
        file_menu.addAction(plane_action)

        file_menu.addSeparator()

        quit_action = QAction("退出", self)
        quit_action.setShortcut(QKeySequence.StandardKey.Quit)
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)

    def bytes_to_text(self, value: int) -> str:
        units = ["B", "KB", "MB", "GB", "TB"]
        size = float(value)
        for unit in units:
            if size < 1024.0 or unit == units[-1]:
                return f"{size:.2f} {unit}"
            size /= 1024.0
        return f"{value} B"

    def update_info_panel(self):
        if not self.video.is_loaded():
            self.path_value.setText("-")
            self.origin_value.setText("-")
            self.loaded_value.setText("-")
            self.volume_value.setText("-")
            self.view_value.setText("-")
            self.memory_value.setText("-")
            self.alpha_value.setText("-")
            self.source_value.setText("-")
            self.plane_value.setText("-")
            self.frame_text_label.setText("当前索引：- / -")
            return

        meta = self.video.meta
        self.path_value.setText(meta.source_path)
        self.origin_value.setText(f"{meta.original_width} × {meta.original_height}，约 {meta.original_frame_count} 帧，{meta.original_fps:.2f} fps")
        self.loaded_value.setText(f"{meta.loaded_width} × {meta.loaded_height}，实际载入 {meta.loaded_frame_count} 帧")
        self.volume_value.setText(str(self.video.volume.shape) if self.video.volume is not None else "-")
        self.memory_value.setText(self.bytes_to_text(self.video.memory_usage_bytes()))
        if meta.has_alpha:
            toggle_text = "启用" if self.alpha_checkbox.isChecked() else "关闭"
            self.alpha_value.setText(f"已检测到 Alpha；2D 网格预览 / 3D 透明识别当前：{toggle_text}\n{meta.alpha_note}")
        else:
            self.alpha_value.setText(meta.alpha_note)

        u_vec, v_vec, n_vec = self.cube_view.get_reference_plane_axes()
        plane_text = (
            f"u=({u_vec[0]:.2f}, {u_vec[1]:.2f}, {u_vec[2]:.2f})\n"
            f"v=({v_vec[0]:.2f}, {v_vec[1]:.2f}, {v_vec[2]:.2f})\n"
            f"n=({n_vec[0]:.2f}, {n_vec[1]:.2f}, {n_vec[2]:.2f})"
        )
        self.plane_value.setText(plane_text)

        if self.view is not None:
            total = self.view.shape[2]
            self.frame_text_label.setText(f"当前索引：{self.current_index} / {max(0, total - 1)}")
            if self.current_view_source == "axis":
                time_axis, h_axis, v_axis = self.mode_combo.currentData()
                self.view_value.setText(f"view[{v_axis},{h_axis},{time_axis},c] = {self.view.shape}")
                self.source_value.setText("轴模式")
            else:
                sample_scale = 1.0
                extra = ""
                if self.oblique_info is not None:
                    sample_scale = float(self.oblique_info.get("sample_scale", 1.0))
                    extra = f"，降采样倍数≈{sample_scale:.2f}" if sample_scale > 1.02 else ""
                self.view_value.setText(f"reference_plane_view = {self.view.shape}{extra}")
                self.source_value.setText("参考面切片")
        else:
            self.view_value.setText("-")
            self.source_value.setText("-")
            self.frame_text_label.setText("当前索引：- / -")

    def _video_file_filter(self) -> str:
        return "视频文件 (*.mp4 *.mov *.avi *.mkv *.m4v *.wmv *.flv *.webm);;所有文件 (*)"

    def _pick_open_video_path(self) -> str:
        dialog = QFileDialog(self, "选择视频文件")
        dialog.setFileMode(QFileDialog.FileMode.ExistingFile)
        dialog.setAcceptMode(QFileDialog.AcceptMode.AcceptOpen)
        dialog.setNameFilter(self._video_file_filter())
        dialog.setOption(QFileDialog.Option.DontUseNativeDialog, True)
        dialog.setDirectory(QDir.homePath())
        dialog.resize(980, 640)
        if not dialog.exec():
            return ""
        files = dialog.selectedFiles()
        return files[0] if files else ""

    def _pick_save_video_path(self, default_name: str) -> str:
        dialog = QFileDialog(self, "导出当前模式为 MP4")
        dialog.setAcceptMode(QFileDialog.AcceptMode.AcceptSave)
        dialog.setFileMode(QFileDialog.FileMode.AnyFile)
        dialog.setNameFilter("MP4 视频 (*.mp4)")
        dialog.setDefaultSuffix("mp4")
        dialog.setOption(QFileDialog.Option.DontUseNativeDialog, True)
        dialog.setDirectory(os.path.dirname(default_name) or QDir.homePath())
        dialog.selectFile(os.path.basename(default_name))
        dialog.resize(980, 640)
        if not dialog.exec():
            return ""
        files = dialog.selectedFiles()
        return files[0] if files else ""

    def open_video(self):
        path = self._pick_open_video_path()
        if not path:
            return

        self.stop_playback()
        self.preview_label.setText("正在导入视频，请稍候…")
        self.statusBar().showMessage("正在导入视频…")
        QApplication.processEvents()

        try:
            self.video.load_video(path, max_side=int(self.max_side_box.value()))
        except Exception as exc:
            QMessageBox.critical(self, "导入失败", str(exc))
            self.preview_label.setText("导入失败")
            self.statusBar().showMessage("导入失败")
            return

        self.mode_combo.setEnabled(True)
        self.play_btn.setEnabled(True)
        self.stop_btn.setEnabled(True)
        self.export_btn.setEnabled(True)
        self.reset_3d_btn.setEnabled(True)
        self.reset_plane_btn.setEnabled(True)
        self.apply_plane_btn.setEnabled(True)
        self.restore_axis_btn.setEnabled(True)
        self.slider.setEnabled(True)

        self.play_fps_box.setValue(max(1.0, self.video.meta.original_fps))
        self.export_fps_box.setValue(max(1.0, self.video.meta.original_fps))

        self.alpha_checkbox.setEnabled(True)
        self.cube_view.set_alpha_enabled(self.alpha_checkbox.isChecked())
        self.cube_view.set_volume(self.video.volume, self.video.alpha_volume)
        self.current_view_source = "axis"
        self.oblique_info = None
        self.rebuild_view()
        self.statusBar().showMessage("导入完成")

    def rebuild_view(self):
        if not self.video.is_loaded():
            return

        time_axis, h_axis, v_axis = self.mode_combo.currentData()
        self.view = self.video.get_view(time_axis, h_axis, v_axis)
        if self.video.alpha_volume is not None:
            order = [AXIS_INDEX[v_axis], AXIS_INDEX[h_axis], AXIS_INDEX[time_axis]]
            self.alpha_view = np.transpose(self.video.alpha_volume, axes=order)
            if not np.any(self.alpha_view < 255):
                self.alpha_view = None
        else:
            self.alpha_view = None
        self.current_view_source = "axis"
        self.oblique_info = None
        total = int(self.view.shape[2])
        self.current_index = 0

        self.slider.blockSignals(True)
        self.slider.setRange(0, max(0, total - 1))
        self.slider.setValue(0)
        self.slider.blockSignals(False)

        self.render_current_frame()
        self.update_info_panel()
        self.statusBar().showMessage(f"已切换模式：时间轴={time_axis}，横轴={h_axis}，纵轴={v_axis}")

    def _progress_callback(self, dialog: QProgressDialog, current: int, total: int):
        if dialog.maximum() != total:
            dialog.setMaximum(total)
        dialog.setValue(current)
        if current % 2 == 0:
            QApplication.processEvents()

    def apply_reference_plane_view(self, auto_trigger: bool = False):
        if self.video.volume is None:
            QMessageBox.information(self, "提示", "请先导入视频")
            return

        self.stop_playback()
        dialog = QProgressDialog("正在根据参考面生成切片视图…", "取消", 0, 1, self)
        dialog.setWindowTitle("生成参考面切片")
        dialog.setWindowModality(Qt.WindowModality.WindowModal)
        dialog.setMinimumDuration(0)
        dialog.setValue(0)

        self.statusBar().showMessage("正在根据参考面生成切片视图…")
        QApplication.processEvents()

        try:
            view, alpha_view, info = self.video.build_oblique_view(
                self.cube_view.get_reference_plane_quaternion(),
                progress_cb=lambda c, t: self._progress_callback(dialog, c, t),
                cancel_cb=dialog.wasCanceled,
            )
        except InterruptedError:
            dialog.close()
            self.statusBar().showMessage("已取消参考面切片生成")
            if not auto_trigger:
                QMessageBox.information(self, "已取消", "已取消根据参考面生成 2D 切片视图。")
            return
        except Exception as exc:
            dialog.close()
            self.statusBar().showMessage("生成参考面切片失败")
            QMessageBox.critical(self, "生成失败", str(exc))
            return
        finally:
            dialog.close()

        self.view = view
        self.alpha_view = alpha_view
        self.current_view_source = "plane"
        self.oblique_info = info
        self.current_index = 0

        total = int(self.view.shape[2])
        self.slider.blockSignals(True)
        self.slider.setRange(0, max(0, total - 1))
        self.slider.setValue(0)
        self.slider.blockSignals(False)

        self.render_current_frame()
        self.update_info_panel()
        shape_text = " × ".join(str(v) for v in self.view.shape[:3])
        self.statusBar().showMessage(f"已切换到参考面切片视图：{shape_text}")
        if not auto_trigger:
            self.tab_widget.setCurrentIndex(0)

    def on_reference_plane_changed(self):
        self.update_info_panel()
        if self.video.is_loaded() and self.current_view_source == "plane" and not self._auto_refreshing_plane:
            self._auto_refreshing_plane = True
            try:
                self.apply_reference_plane_view(auto_trigger=True)
            finally:
                self._auto_refreshing_plane = False
        else:
            self.statusBar().showMessage("参考面已更新。点击“以参考面生成 2D 切片视图”可切换预览。")

    def on_alpha_checkbox_toggled(self, checked: bool):
        self.cube_view.set_alpha_enabled(checked)
        self.render_current_frame()
        self.update_info_panel()
        state = "启用" if checked else "关闭"
        self.statusBar().showMessage(f"Alpha 识别（2D/3D）已{state}")

    def update_timer_interval(self):
        fps = max(1.0, float(self.play_fps_box.value()))
        interval_ms = max(1, int(round(1000.0 / fps)))
        self.timer.setInterval(interval_ms)

    def toggle_play(self):
        if self.view is None:
            return

        if self.timer.isActive():
            self.stop_playback()
        else:
            self.timer.start()
            self.play_btn.setText("暂停")
            self.statusBar().showMessage("播放中")

    def stop_playback(self):
        self.timer.stop()
        self.play_btn.setText("播放")

    def stop_and_reset(self):
        self.stop_playback()
        if self.view is not None:
            self.current_index = 0
            self.slider.setValue(0)
            self.render_current_frame()
        self.statusBar().showMessage("已停止并回到起点")

    def next_frame(self):
        if self.view is None:
            return

        total = self.view.shape[2]
        if total <= 0:
            return

        self.current_index += 1
        if self.current_index >= total:
            self.current_index = 0

        self.slider.blockSignals(True)
        self.slider.setValue(self.current_index)
        self.slider.blockSignals(False)
        self.render_current_frame()

    def on_slider_moved(self, value: int):
        if self.view is None:
            return

        self.current_index = int(value)
        self.render_current_frame()
        self.statusBar().showMessage(f"已跳转到索引 {self.current_index}")

    def _build_checkerboard(self, height: int, width: int, tile: int = 16) -> np.ndarray:
        yy = (np.arange(height) // tile)[:, None]
        xx = (np.arange(width) // tile)[None, :]
        pattern = ((yy + xx) % 2).astype(np.uint8)
        light = np.full((height, width, 3), 214, dtype=np.uint8)
        dark = np.full((height, width, 3), 168, dtype=np.uint8)
        return np.where(pattern[..., None] == 0, light, dark)

    def _compose_preview_frame(self, frame: np.ndarray, alpha_frame: np.ndarray | None) -> np.ndarray:
        if not self.alpha_checkbox.isChecked() or alpha_frame is None:
            return frame
        alpha = alpha_frame.astype(np.float32) / 255.0
        if np.all(alpha >= 0.999):
            return frame
        bg = self._build_checkerboard(frame.shape[0], frame.shape[1])
        out = frame.astype(np.float32) * alpha[..., None] + bg.astype(np.float32) * (1.0 - alpha[..., None])
        return np.clip(out, 0.0, 255.0).astype(np.uint8)

    def render_current_frame(self):
        if self.view is None:
            self.preview_label.setText("暂无视图")
            return

        t = max(0, min(self.current_index, self.view.shape[2] - 1))
        frame = np.ascontiguousarray(self.view[:, :, t, :])

        alpha_frame = None
        if self.alpha_view is not None and 0 <= t < self.alpha_view.shape[2]:
            alpha_frame = np.ascontiguousarray(self.alpha_view[:, :, t])

        frame_to_show = np.ascontiguousarray(self._compose_preview_frame(frame, alpha_frame))
        h, w, ch = frame_to_show.shape
        bytes_per_line = w * ch

        image = QImage(frame_to_show.data, w, h, bytes_per_line, QImage.Format.Format_RGB888).copy()
        pixmap = QPixmap.fromImage(image)
        target_size = self.preview_label.size()
        if target_size.width() > 10 and target_size.height() > 10:
            pixmap = pixmap.scaled(target_size, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)

        self.preview_label.setPixmap(pixmap)
        self.update_info_panel()

    def export_current_view(self):
        if self.view is None:
            QMessageBox.information(self, "提示", "请先导入视频")
            return

        default_name = self.default_export_name()
        path = self._pick_save_video_path(default_name)
        if not path:
            return

        if not path.lower().endswith(".mp4"):
            path += ".mp4"

        view = self.view
        height, width, total_frames, _ = view.shape
        export_fps = max(1.0, float(self.export_fps_box.value()))

        fourcc_candidates = ["mp4v", "avc1"]
        writer = None
        selected_fourcc = None
        for code in fourcc_candidates:
            trial = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*code), export_fps, (width, height))
            if trial.isOpened():
                writer = trial
                selected_fourcc = code
                break
            trial.release()

        if writer is None:
            QMessageBox.critical(self, "导出失败", "无法创建视频写入器。你可以尝试更换导出路径，或确认 OpenCV 是否支持 MP4 编码。")
            return

        progress = QProgressDialog("正在导出视频…", "取消", 0, total_frames, self)
        progress.setWindowTitle("导出中")
        progress.setWindowModality(Qt.WindowModality.WindowModal)
        progress.setMinimumDuration(0)
        progress.setValue(0)

        self.stop_playback()
        self.statusBar().showMessage(f"开始导出，编码器={selected_fourcc}")
        QApplication.processEvents()

        cancelled = False
        try:
            for i in range(total_frames):
                if progress.wasCanceled():
                    cancelled = True
                    break

                frame_rgb = np.ascontiguousarray(view[:, :, i, :])
                frame_bgr = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR)
                writer.write(frame_bgr)

                progress.setValue(i + 1)
                if i % 10 == 0:
                    QApplication.processEvents()
        finally:
            writer.release()
            progress.close()

        if cancelled:
            if os.path.exists(path):
                try:
                    os.remove(path)
                except OSError:
                    pass
            self.statusBar().showMessage("导出已取消")
            QMessageBox.information(self, "已取消", "导出已取消，未保留输出文件。")
            return

        self.statusBar().showMessage("导出完成")
        QMessageBox.information(
            self,
            "导出成功",
            f"已导出到：\n{path}\n\n分辨率：{width} × {height}\n总帧数：{total_frames}\n帧率：{export_fps:.2f} fps",
        )

    def default_export_name(self) -> str:
        if not self.video.is_loaded():
            return os.path.join(os.path.expanduser("~"), "timevideo_export.mp4")

        src = os.path.splitext(os.path.basename(self.video.meta.source_path))[0]
        if self.current_view_source == "plane":
            filename = f"{src}_reference_plane.mp4"
        else:
            time_axis, h_axis, v_axis = self.mode_combo.currentData()
            filename = f"{src}_T{time_axis}_H{h_axis}_V{v_axis}.mp4"
        return os.path.join(os.path.dirname(self.video.meta.source_path), filename)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if self.view is not None:
            self.render_current_frame()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Space:
            self.toggle_play()
            return

        if event.key() == Qt.Key.Key_R and (event.modifiers() & Qt.KeyboardModifier.ShiftModifier):
            self.cube_view.reset_reference_plane()
            return

        if event.key() == Qt.Key.Key_R:
            self.cube_view.reset_camera()
            return

        if self.view is not None:
            if event.key() == Qt.Key.Key_Right:
                self.stop_playback()
                self.current_index = min(self.current_index + 1, self.view.shape[2] - 1)
                self.slider.setValue(self.current_index)
                self.render_current_frame()
                return

            if event.key() == Qt.Key.Key_Left:
                self.stop_playback()
                self.current_index = max(self.current_index - 1, 0)
                self.slider.setValue(self.current_index)
                self.render_current_frame()
                return

        super().keyPressEvent(event)

    def closeEvent(self, event):
        self.video.clear()
        self.cube_view.set_volume(None)
        super().closeEvent(event)


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("ChronoVolume-原型程序")
    window = MainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
