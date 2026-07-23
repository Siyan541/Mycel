import numpy as np
from astropy.io import fits
from music21 import stream, note, instrument, scale, harmony, pitch, meter, tempo, dynamics
from music21 import expressions, duration, midi
from music21 import *
from music21.dynamics import Crescendo
import pywt
import logging
logging.basicConfig(level=logging.INFO)
from astropy.table import Table
from music21.instrument import SnareDrum, BassDrum
import os
from music21 import environment
from music21 import midi
import random
from scipy.signal import savgol_filter

# 配置核心参数
env = environment.Environment()
env['autoDownload'] = 'allow'  # 允许自动下载必要组件

# 指定FluidSynth路径（根据实际安装位置）
midi.realtime.fluidsynthPath = '/opt/homebrew/bin/fluidsynth'  # 通过`which fluidsynth`获取

# 指定SoundFont路径（在需要时显式调用）
SOUNDFONT_PATH = '/Users/siyanwu/soundfonts/FluidR3_GM.sf2'


JAZZ_CONFIG = {
    'swing_ratio': 0.67,  # 标准swing比例
    'walking_bass': True,
    'blue_notes': [3, 5, 7],  # 蓝调音级
    'comping_density': 0.8,  # 钢琴伴奏密度
    'improvisation_intensity': 0.6  # 即兴强度
}

# --------------------------
# 天文参数映射配置
# --------------------------
PARAM_MAPPING = {
    'wavelength': {
        'element': 'chord_complexity',
        'mapping': lambda wl: (np.var(wl)/1e6, 0, 3)  # 波长方差→和弦紧张度
    },
    'flux_derivative': {
        'element': 'rhythm_density',
        'mapping': lambda df: (np.mean(np.abs(df))*100, 0, 1)
    },
    'feh': {
        'element': 'scale_mode',
        'mapping': lambda feh: 'blues' if feh < -0.5 else 'mixolydian' if feh < 0 else 'dorian'
    },
    'z': {
        'element': ['transpose', 'tempo'],
        'mapping': lambda z: (int(z*12), 100 + z*20)  # 红移影响移调和速度
    },
    'emission_lines': {
        'element': 'timbre_change',
        'mapping': lambda lines: {line: intensity for line, intensity in lines}
    },
    'teff': {
        'element': 'instrument',
        'mapping': lambda teff: 'violin' if teff > 7000 else 'cello' if teff > 5000 else 'piano'
    },
    'logg': {
        'element': 'comping_style',
        'mapping': lambda logg: 'block_chords' if logg > 4 else 'walking_bass'
    }
}

class JazzHarmonyGenerator:
    def __init__(self, astro_data):
        self.data = astro_data
        self.blue_scale = self._create_blue_scale()
        
    def _create_blue_scale(self):
        """创建带蓝调音的音阶"""
        base_scale = scale.MixolydianScale('C4')
        blue_notes = [p.transpose(-0.5) for p in base_scale.pitches if p.scaleDegree in JAZZ_CONFIG['blue_notes']]
        return base_scale.derive(alterations={deg: -0.5 for deg in JAZZ_CONFIG['blue_notes']})
    
    def generate_progression(self):
        """生成爵士和声进行"""
        # 标准爵士进行变体
        progressions = [
            ['I7', 'VI7', 'II7', 'V7'],
            ['I7', 'IV7', 'I7', 'V7'],
            ['III7', 'VI7', 'II7', 'V7']
        ]
        selected = random.choice(progressions)
        
        chords = []
        for roman in selected:
            root = self.blue_scale.pitchFromDegree(roman[:1])
            chord_type = '7'  # 默认属七和弦
            if 'm7' in roman:
                chord_type = 'm7'
            chords.append(harmony.ChordSymbol(root=root, kind=chord_type))
        
        return self._add_tensions(chords)
    
    def _add_tensions(self, chords):
        """添加爵士张力音"""
        for i, chord in enumerate(chords):
            # 根据金属丰度决定张力复杂度
            tension_level = min(int(self.data['feh'] * 3), 3)
            extensions = {
                1: ['9'],
                2: ['9', '13'],
                3: ['b9', '#11', '13']
            }.get(tension_level, [])
            
            if extensions:
                chord.addExtensions(extensions)
        return chords
# --------------------------
# 核心音乐生成引擎
# --------------------------
class AstroMusicGenerator:

    def __init__(self, fits_path):
        self.data = self._load_and_process_data(fits_path)
        self.score = stream.Score()
        self._apply_global_settings()
        self.key = key.Key('C') 
        self.spatial_pan = 0.0
        self.reverb_strength = 1.0
        self.rhythm_template = [1.0, 1.0, 1.0, 1.0]  # 全音符分解为四分音符
        
    def data_cleaning(self, flux):
            """数据清洗函数"""
            # 去除无效通量值（通常标记为NaN或0）
            valid_mask = (np.isfinite(flux)) & (flux > 0)
            clean_flux = flux[valid_mask]

            # 处理全无效数据的情况
            if len(clean_flux) == 0:
                clean_flux = np.zeros_like(flux)  # 生成默认值

            # 填充剩余NaN
            clean_flux = np.nan_to_num(clean_flux, nan=np.nanmedian(clean_flux))

            # 通量归一化（避免音量过大）
            normalized_flux = (clean_flux - np.min(clean_flux)) / \
                     (np.max(clean_flux) - np.min(clean_flux) + 1e-8)  # 防止除零
            
            return normalized_flux

    def wavelet_denoising(self, flux, level=5):
        """
        改进版小波去噪，确保输出长度与输入一致
        :param flux: 原始通量数组
        :param level: 小波分解层数
        :return: 去噪后的通量数组（长度与输入相同）
        """
        # 原始长度
        original_len = len(flux)
        
        # 计算填充长度（使长度为2^level的倍数）
        desired_len = int(np.ceil(original_len / (2**level)) * (2**level))
        pad_width = desired_len - original_len
    
        # 对称填充（避免边缘效应）
        padded_flux = np.pad(flux, (0, pad_width), mode='symmetric')
    
        # 小波分解与去噪
        coeffs = pywt.wavedec(padded_flux, 'db4', mode='per', level=level)
        sigma = np.median(np.abs(coeffs[-1])) / 0.6745  # 鲁棒噪声估计
        threshold = sigma * np.sqrt(2 * np.log(len(padded_flux)))
        denoised_coeffs = [pywt.threshold(c, threshold) for c in coeffs]
    
        # 重构并截断
        denoised_padded = pywt.waverec(denoised_coeffs, 'db4', mode='per')
        denoised_flux = denoised_padded[:original_len]
    
        return denoised_flux
    
    def _load_and_process_data(self, fits_path):
        """加载SDSS光谱FITS文件并提取关键参数"""
        if not os.path.exists(fits_path):
            raise FileNotFoundError(f"文件 {fits_path} 不存在")
    
        with fits.open(fits_path) as hdul:
            # 提取光谱数据
            data = hdul[1].data
            wl = 10**data['loglam']  # 对数波长转线性波长（单位：Å）
            flux = data['flux']              # 通量值（单位：10⁻17 erg/cm²/s/Å）
        
            # 提取元数据（位于第2个HDU的SPECOBJ表）
            metadata = hdul[2].data
        
            # 数据清洗
            normalized_flux = self.data_cleaning(flux)
            valid_mask = (flux > 0) & np.isfinite(flux)
            clean_wl = wl[valid_mask]
        
            # 第一次长度验证
            if len(clean_wl) != len(normalized_flux):
                raise ValueError("清洗后波长与通量长度不一致")
        
            # 小波去噪
            try:
                denoised_flux = self.wavelet_denoising(normalized_flux)
            except ValueError as e:
                print(f"去噪失败: {str(e)}，使用原始数据")
                denoised_flux = normalized_flux
        
            # 最终长度验证
            if len(denoised_flux) != len(clean_wl):
                raise RuntimeError(f"去噪后长度异常（输入{len(clean_wl)}，输出{len(denoised_flux)}）")
            assert len(clean_wl) == len(denoised_flux)

            return {
                'wavelength': clean_wl,
                'flux': denoised_flux,
                'z': metadata['Z'][0],         # 红移
                'teff': metadata['ELODIE_TEFF'][0],          # 有效温度（K）
                'feh': metadata['ELODIE_FEH'][0],            # 金属丰度[Fe/H]
                'logg': metadata['ELODIE_LOGG'][0],           # 表面重力（log cm/s²）
                'snr': np.median(denoised_flux) / np.std(denoised_flux),  # 信噪比
                'emission_lines': self._detect_emission_lines(clean_wl, denoised_flux)  # 检测发射线
            }

    def _detect_emission_lines(self, wl, flux):
        """检测主要发射线"""
        peaks = []
        for line in [6563, 4861, 4340]:  # Hα, Hβ, Hγ
            # 使用 numpy 的 argmin 正确查找索引
            idx = np.argmin(np.abs(wl - line))
            if flux[idx] > np.percentile(flux, 90):
                peaks.append(('H' + str(line), flux[idx]))  # 简化名称生成逻辑
        return peaks

    def _apply_global_settings(self):
        """确保音阶对象必定创建"""
        """应用全局音乐参数"""
        # 调式选择
        try:
            scale_mode = PARAM_MAPPING['feh']['mapping'](self.data['feh'])
            self.scale = {
                'minor': scale.HarmonicMinorScale('C4'),
                'lydian': scale.LydianScale('G4')
            }.get(scale_mode, scale.MajorScale('C4'))  # 添加默认值
            
            # 添加closestPitch方法
            self.scale.closestPitch = lambda p: min(
                self.scale.getPitches(),
                key=lambda x: abs(x.midi - p.midi))
        except Exception as e:
            logging.error(f"音阶初始化失败: {str(e)}")
            self.scale = scale.MajorScale('C4')
            self.scale.closestPitch = lambda p: p  # 简单容错
        
        
        # 移调与速度
        transpose, tempo_factor = PARAM_MAPPING['z']['mapping'](self.data['z'])
        self.score.insert(0, tempo.MetronomeMark(
            number=80 * tempo_factor))
        self.transpose = transpose

        pass

    def generate_full_composition(self):
        """生成3-5分钟的完整爵士乐曲"""
        full_score = stream.Score()
            
        # 前奏 (30秒)
        intro = self._generate_intro()
        full_score.append(intro)

        # 主题呈示 (60秒)
        theme_a = self._generate_jazz_melody()
        full_score.append(theme_a)

        # 即兴段落 (90秒)
        solos = self._generate_improvisation_section()
        full_score.append(solos)

        # 主题再现 (30秒)
        theme_b = theme_a.transpose(5)  # 上移四度
        full_score.append(theme_b)

        # 结尾 (30秒)
        outro = self._generate_outro()
        full_score.append(outro)

        # 动态调整总时长
        target_duration = 240 + (self.data['z'] * 60)  # 基础4分钟 + 红移影响
        return self._adjust_duration(full_score, target_duration)

    def _adjust_duration(self, score, target_seconds):
        """精确调整时长"""
        current_seconds = score.duration.quarterLength * 0.5  # 假设120bpm
        ratio = target_seconds / current_seconds
        return score.scaleDurations(ratio)
    

    #PREVIOUSLY DEFINED FUNCTION
    def generate_track(self, data, instr, track_type='melody'):
        """
        生成单个乐器音轨
        :param data: 包含波长、通量的字典
        :param instr: music21乐器对象
        :param track_type: melody/rhythm
        """
        s = stream.Part()
        s.append(instr)
    
        # 参数预处理
        wl = data['wavelength']
        flux = data['flux']
        flux_norm = (flux - np.min(flux)) / (np.max(flux) - np.min(flux))
    
        assert len(wl) == len(flux)

        if track_type == 'melody':
            # 主旋律生成：
            mask = (wl > 4000) & (wl < 8000)
            # 同步应用掩码
            wl_masked = wl[mask]
            flux_masked = flux[mask]
    
            # 再次验证
            assert len(wl_masked) == len(flux_masked), "掩码后长度不一致"
    
            # 降采样（保持同步）
            step = 10
            wl_sampled = wl_masked[::step]
            flux_sampled = flux_masked[::step]

            for w, f in zip(wl_sampled, flux_sampled):  # 降采样
                midi_num = 60 + int((w - 6500) / 100 * 12)
                n = note.Note(midi_num)
                n.duration.quarterLength = 0.25 + f * 2
                n.volume.velocity = int(f * 127)
                s.append(n)
            
        elif track_type == 'rhythm':
            # 节奏生成：基于通量方差生成打击乐
            window_size = 50
            variances = [np.var(flux_norm[i:i+window_size]) 
                        for i in range(0, len(flux_norm), window_size)]
            for var in variances:
                if var > 0.1:
                    s.append(note.Note('D2', quarterLength=0.25)) 
                    s.insert(0, SnareDrum()) 
                elif var > 0.05:
                    s.append(note.Rest(quarterLength=0.25))
    
        return s
    
    def generate_melody(self, data, instr):
        """主旋律生成（包装方法）"""
        s = stream.Part()
        s.append(instr)  # 确保传入的乐器实例被添加
        return self.generate_track(data, instr, 'melody')
    
    def generate_harmony(self, wavelength, flux):
        """基于光谱特征生成动态和弦"""
        chord_progression = []
    
        # 计算局部通量峰值作为和弦变化点
        peak_indices = np.where(np.diff(np.sign(np.diff(flux))) < 0)[0] + 1
    
        for i in range(0, len(peak_indices)-1):
            segment = flux[peak_indices[i]:peak_indices[i+1]]
            wl_segment = wavelength[peak_indices[i]:peak_indices[i+1]]
        
            # 特征提取
            flux_var = np.var(segment)
            wl_skew = np.mean(wl_segment) / 1000  # 归一化到可见光范围
        
            # 和弦选择逻辑
            if flux_var > 0.1:
                root = pitch.Pitch(int(60 + (wl_skew % 12)))
                chord_type = 'dominant7' if wl_skew > 6 else 'minor7'
            else:
                root = pitch.Pitch(60 + int(len(segment)/100))
                chord_type = 'major'
        
            # 添加张力音
            extensions = ['9', '11'] if flux_var > 0.05 else []
            chord_obj = harmony.ChordSymbol(root=root, kind=chord_type, 
                                        extensions=extensions)
            chord_progression.append(chord_obj)
    
        return chord_progression

    def generate_rhythm(self, flux, snr):
        rhythm_stream = stream.Part()
        rhythm_stream.append(instrument.SnareDrum())

        """基于通量信噪比生成复合节奏"""
        flux_diff = np.diff(flux)
        flux_norm = (flux_diff - np.min(flux_diff)) / (np.max(flux_diff) - np.min(flux_diff))
    
        rhythm_stream = stream.Part()
        rhythm_stream.append(instrument.SnareDrum())
    
        # 基础节奏型：直接使用 quarterLength 数值（例如：0.25=16分音符，1.0=全音符）
        basic_rhythm = [0.25, 1.0, 0.5]  # 分别对应16分、全音符、2分音符
        # 根据信噪比添加复杂度
        complexity = int(snr / 10)  # 假设snr范围0-50
    
        for i in range(len(flux_norm)):
            prob = flux_norm[i]
            if np.random.rand() < prob**2:  # 非线性概率
                dur = basic_rhythm[np.random.choice(len(basic_rhythm))]
                if complexity > 3:
                    dur = dur * 2/3
                snare = note.Note('D2', quarterLength=dur)
                rhythm_stream.append(snare)
            else:
                rhythm_stream.append(note.Rest(quarterLength=0.25))
    
        # 添加随机填充
        if complexity > 2:
            fill = stream.Measure()
            fill.append(note.Note('A2', quarterLength=0.125))
            fill.append(note.Note('C3', quarterLength=0.125))
            rhythm_stream.insert(np.random.randint(4, len(rhythm_stream)), fill)
    
        return rhythm_stream
    
    def _segment_spectrum(self):
        """分段光谱数据"""
        # 简单分段：每100个数据点为一段
        segment_size = 100
        segments = []
        for i in range(0, len(self.data['flux']), segment_size):
            segment = {
                'wl': self.data['wavelength'][i:i+segment_size],
                'flux': self.data['flux'][i:i+segment_size]
            }
            segments.append(segment)
        return segments
    

    def _add_harmony_layer(self):
        """智能和声生成"""
        chord_prog = []
        for seg in self._segment_spectrum():
            # 动态和弦生成逻辑
            tension = PARAM_MAPPING['wavelength']['mapping'](seg['wl'])[0]
            chord_type = 'maj7' if tension > 1.5 else 'min7'
            root = self.scale.getPitches()[int(len(seg['flux'])%7)]
            
            # 添加扩展音
            extensions = ['9', '11'] if tension > 2 else []
            chord_prog.append(harmony.ChordSymbol(
                root=root.transpose(self.transpose),
                kind=chord_type,
                extensions=extensions
            ))
        
        harmony_part = stream.Part(instrument.Piano())
        harmony_part.append(chord_prog)
        self.score.append(harmony_part)

    def _add_melody_layer(self):
        """主旋律生成（基于节奏模板）"""
        melody_stream = stream.Part(instrument.Violin())
        for step, dur in enumerate(self.rhythm_template):
            # 动态选择音高（示例）
            midi_num = 60 + int(self.data['flux'][step % len(self.data['flux'])] * 12)
            n = note.Note(midi_num)
            n.duration.quarterLength = dur
            melody_stream.append(n)
        self.score.append(melody_stream)

        """装饰旋律生成"""
        # 核心旋律生成（基于先前实现）
        melody = self.generate_melody(
            self.data, 
            instrument.Violin()
        ).transpose(self.transpose)
        
        # 添加装饰音
        decorated_melody = self.decorate_melody(melody)
        
        # 应用动态表情
        self._apply_dynamics(decorated_melody, self.data['flux'])
        
        self.score.append(decorated_melody)

    def _apply_dynamics(self, melody_stream, flux):
        """应用动态表情"""
        try:
            flux_norm = (flux - np.min(flux)) / (np.max(flux) - np.min(flux))
            flux_norm = np.asarray(flux_norm).flatten() 
            notes = list(melody_stream.flatten().notes)
            if not notes:
                return
            
            step = max(len(flux_norm) // len(notes), 1)
            flux_sampled = flux_norm[::step]
        
            # 循环填充不足部分（例如：flux长度不足时）
            if len(flux_sampled) < len(notes):
                flux_sampled = np.tile(flux_sampled, (len(notes) // len(flux_sampled) + 1))[:len(notes)] 

            for n, f in zip(notes, flux_sampled):
                f_scalar = float(f)
                n.volume.velocity = int(70 + 50 * f_scalar)
                if f_scalar > 0.7:
                    n.expressions.append(dynamics.Crescendo())
                elif f_scalar < 0.3:
                    n.expressions.append(dynamics.Diminuendo())
        except Exception as e:
            logging.error(f"动态处理失败: {str(e)}")

    def _add_rhythm_layer(self):
        """爵士节奏组生成"""
        # 钢琴comping
        piano_part = self._generate_comping()

        # 鼓组（保留轻量爵士鼓）
        drum_part = self._generate_jazz_drums()

        self.score.append(piano_part)
        self.score.append(drum_part)

    def _generate_comping(self):
        """生成爵士钢琴伴奏"""
        comping = stream.Part(instrument.AcousticBass())
        chords = self.jazz_harmony.generate_progression()

        for chord in chords:
            # 根据logg选择伴奏型
            if self.data['logg'] > 4:
                # Block chords
                for p in chord.pitches[:3]:
                    n = note.Note(p, quarterLength=0.5)
                    comping.append(n)
            else:
                # Shell voicings
                root = chord.root()
                fifth = chord.fifth()
                comping.append(note.Note(root, quarterLength=1))
                comping.append(note.Note(fifth, quarterLength=1))

        return comping

    def _generate_jazz_drums(self):
        """轻量爵士鼓组"""
        drums = stream.Part(instrument.DrumSet())
        # 基本ride节奏型
        ride_pattern = ['C5', None, 'C5', None] * 16
        # 添加踩镲开合
        hihat_pattern = [None, 'F#5', None, 'G#5'] * 16

        for r, h in zip(ride_pattern, hihat_pattern):
            if r:
                drums.append(note.Note(r, quarterLength=0.5))
            if h:
                drums.append(note.Note(h, quarterLength=0.25))

        return drums
    
    def _generate_walking_bass(self):
        """行走低音生成"""
        bass = stream.Part(instrument.AcousticBass())
        chords = self.jazz_harmony.generate_progression()

        for chord in chords:
            # 生成walking bass线
            root = chord.root()
            walk = [root, 
                   root.transpose(2), 
                   root.transpose(4), 
                   root.transpose(5)]

            for p in walk:
                n = note.Note(p, quarterLength=0.5)
                # 添加滑音效果
                if random.random() < 0.3:
                    n.expressions.append(expressions.Glide())
                bass.append(n)

        return bass

# 根据发射线强度调整打击乐强度 ?

    def _add_bass_layer(self):
        """行走低音生成"""
        # 基于和弦进行生成（需实现和弦分析）
        bass_part = self._generate_metallicity_bass()
        if not bass_part.notes:
            bass_part.append(note.Rest(quarterLength=4))  # 添加全休止符
        # ...（和弦跟踪实现）...
        self.score.append(bass_part)

    def _apply_post_processing(self):
        """后期效果处理"""
        
        self._spatial_panning()
        self._add_reverb()
        self._apply_spatial_effects()
        self._dynamic_shaping()

    def _apply_spatial_effects(self):
        """三维声场处理"""
        for part in self.score.parts:
            instr = part.getInstrument()
            instr.pan = self.spatial_pan
            instr.midiProgram = 19 + int(self.reverb_strength * 10)

    def _generate_metallicity_bass(self):
        """根据金属丰度生成低音声部"""
        
        # 获取基础音高
        try:
            base_pitch = self.key.tonic.transpose(-24)
        except AttributeError:
            base_pitch = pitch.Pitch('C2')

        if not hasattr(self, 'key'):
            self.key = key.Key('C')  # 默认C大调
        if not hasattr(self, 'spatial_pan'):
            self.spatial_pan = 0.0


        bass_stream = stream.Part()
        bass_stream.append(instrument.AcousticBass())

        # 获取金属丰度值
        feh = self.data['feh']
    
        # 根据金属丰度选择生成模式
        if feh >= 0:  # 金属丰度高，生成爵士风格低音
            # 获取和弦根音（基于波长统计值）
            root_pitch = self.scale.getPitches()[int(np.mean(self.data['wavelength']) % 7)]

            # 创建行走低音模式
            for i in range(0, len(self.data['flux']), 50):  # 每50个数据点生成一个和弦
                # 添加扩展音：金属丰度越高和弦越复杂
                extensions = []
                if feh > 0.5:
                    extensions = ['7', '9']
                elif feh > 0.2:
                    extensions = ['7']

                # 生成和弦（避免平行五度）
                current_chord = harmony.ChordSymbol(
                    root=root_pitch.transpose(-12),  # 低八度
                    kind='dominant' if feh > 0 else 'major',
                    extensions=extensions
                )

                # 添加节奏变化（基于通量方差）
                flux_segment = self.data['flux'][i:i+50]
                duration = 0.5 + (np.var(flux_segment)/0.1)  # 方差越大时值越长
                current_chord.duration.quarterLength = min(duration, 2.0)

                bass_stream.append(current_chord)

                # 更新根音（在音阶内移动）
                root_pitch = self.scale.nextPitch(root_pitch)

        else:  # 金属丰度低，生成简约低音
            # 选择基础音高（基于主音）
            base_pitch = self.key.tonic.transpose(-24)  # 低两个八度

            # 生成脉冲式低音（基于通量峰值）
            peak_indices = np.where(np.diff(np.sign(np.diff(self.data['flux']))) < 0)[0]
            for idx in peak_indices[::10]:  # 降采样
                n = note.Note(base_pitch)
                n.duration.quarterLength = 0.25
                # 力度映射通量值
                n.volume.velocity = int(40 + 80 * (self.data['flux'][idx]/np.max(self.data['flux'])))
                bass_stream.append(n)
                # 添加休止符保持节奏
                bass_stream.append(note.Rest(quarterLength=0.75))

        # 应用后期处理
        self._smooth_bass_line(bass_stream)
        return bass_stream

    def _smooth_bass_line(self, bass_stream):
        """平滑低音线条（避免大跳）"""
        prev_pitch = None
        for element in bass_stream:
            if isinstance(element, (note.Note, chord.Chord)):
                current_pitch = element.root() if isinstance(element, chord.Chord) else element.pitch
                if prev_pitch:
                    # 限制音程不超过纯四度
                    interval_obj = interval.Interval(prev_pitch, current_pitch)
                    if interval_obj.semitones > 5:
                        # 替换为下行三度
                        new_pitch = prev_pitch.transpose(-3)
                        if isinstance(element, chord.Chord):
                            element.root(new_pitch)
                        else:
                            element.pitch = new_pitch
                prev_pitch = current_pitch
    # --------------------------
    # 音乐性增强方法
    # --------------------------
  
    def decorate_melody(self, melody_stream):
        """为旋律添加音乐性装饰"""
        # 参数化装饰规则
        DECORATION_PROBS = {
            'trill': 0.3,
            'grace_note': 0.4,
            'slide': 0.2,
            'vibrato': 0.6
        }
        for n in melody_stream.flatten().notes:
            # 装饰音添加
            if np.random.rand() < DECORATION_PROBS['grace_note']:
                grace = note.Note(n.pitch.midi - 1)
                grace.duration.quarterLength = 0.1
                melody_stream.append(grace)
            
        return melody_stream
    
    def _apply_pro_processing(self, score):
        """专业音频处理"""
        # 动态平衡
        for part in score.parts:
            self._normalize_part(part)

        # 添加全局效果
        score.insert(0, dynamics.Dynamic('mf'))
        score.insert(0, tempo.MetronomeMark(number=120))

        # 空间定位
        self._apply_3d_panning(score)

        return score

    def _apply_3d_panning(self, score):
        """专业声场定位"""
        pan_positions = {
            'violin': -0.7,
            'piano': 0.3,
            'bass': 0.5,
            'drums': -0.3
        }

        for part in score.parts:
            instr = part.getInstrument()
            for name, pan in pan_positions.items():
                if name in instr.className.lower():
                    instr.pan = pan
                    break
    
    def _spatial_panning(self):
        """立体声声像分布"""
        for i, part in enumerate(self.score.parts):
            pan_value = -0.5 + i*0.3  # 动态分布

        # 确保音轨包含乐器对象
        if not part.getElementsByClass(instrument.Instrument):
            part.insert(0, instrument.Piano())  # 默认添加钢琴
        
        # 获取乐器对象并设置声像
        instr = part.getElementsByClass(instrument.Instrument)[0]
        instr.pan = pan_value

    def _add_reverb(self):
        """红移相关混响（通过音色选择实现）"""
        reverb_strength = 1.0 + self.data['z'] * 0.5  # 红移影响混响强度
        for part in self.score.parts:
            if not part.getElementsByClass(instrument.Instrument):
                part.insert(0, instrument.Piano())
            instr = part.getElementsByClass(instrument.Instrument)[0]
            # 根据红移调整音色（示例：选择不同的MIDI程序号）
            instr.midiProgram = int(19 * reverb_strength)  # 19 为混响较强的音色

    def _dynamic_shaping(self):
        """通量曲线力度控制"""
        try:
            flux_norm = (self.data['flux'] - np.min(self.data['flux'])) / \
                    (np.max(self.data['flux']) - np.min(self.data['flux']))
            dynamic_levels = ['pp', 'p', 'mp', 'mf', 'f', 'ff']
            dynamic_volumes = {'pp': 30, 'p': 50, 'mp': 70, 'mf': 90, 'f': 110, 'ff': 127}
            for n, f in zip(self.score.flatten().notes, flux_norm):
                dynamic_idx = min(int(f * len(dynamic_levels)), len(dynamic_levels) - 1)
                dynamic = dynamics.Dynamic(dynamic_levels[dynamic_idx])
                n.addLyric(dynamic.value) 
                n.volume.velocity = dynamic_volumes[dynamic_levels[dynamic_idx]]  # 根据动态级别自动设置音量
        except Exception as e:
            logging.error(f"动态处理失败: {str(e)}")
 
    def _generate_jazz_melody(self):
        """生成带即兴元素的爵士旋律"""
        melody = stream.Part()
        num_measures = 16  # 16小节结构
        beats_per_measure = 4

        # 使用蓝调音阶
        jazz_scale = self._get_jazz_scale()

        # 生成主题动机
        motif = self._create_motif(jazz_scale)

        for m in range(num_measures):
            # 每4小节变化
            if m % 4 == 0:
                motif = self._vary_motif(motif, jazz_scale)

            # 添加即兴段落
            if random.random() < JAZZ_CONFIG['improvisation_intensity']:
                self._add_improvisation(melody, jazz_scale, beats_per_measure)
            else:
                melody.append(motif.clone())

        return melody

    def _create_motif(self, jazz_scale):
        """创建基于光谱特征的动机"""
        motif = stream.Measure()
        flux_peaks = self._find_flux_peaks(self.data['flux'])

        for i in range(4):  # 4拍基础动机
            if i < len(flux_peaks):
                peak = flux_peaks[i]
                degree = int(peak % 7) + 1  # 映射到音阶级数
                pitch = jazz_scale.pitchFromDegree(degree)

                # 添加swing节奏
                dur = 0.5 if i % 2 == 0 else JAZZ_CONFIG['swing_ratio']
                n = note.Note(pitch, quarterLength=dur)

                # 添加蓝调音装饰
                if random.random() < 0.3:
                    n.pitch.microtone = -50  # 1/4音降
                motif.append(n)

        return motif

    def _add_improvisation(self, stream, jazz_scale, duration):
        """添加即兴段落"""
        current_chord = self.jazz_harmony.get_current_chord()
        arpeggio = self._create_arpeggio(current_chord)

        # 混合音阶和琶音
        for i in range(int(duration * 2)):  # 八分音符密度
            if random.random() < 0.7:
                note_choice = random.choice(arpeggio)
            else:
                note_choice = random.choice(jazz_scale.getPitches('C4','C6'))

            # 添加爵士乐 phrasing
            n = note.Note(note_choice)
            n.duration.quarterLength = random.choice([0.5, 0.25, 0.75])
            stream.append(n)

# 在AstroMusicGenerator.py中添加以下升级内容
from music21.analysis import discrete
from music21 import environment
env = environment.Environment()
env['musicxmlPath'] = '/usr/local/bin/musescore'    # 可选，设置MuseScore路径
env['autoDownload'] = 'allow'                       # 允许自动下载音色库

class EnhancedAstroMusicGenerator(AstroMusicGenerator):
    def __init__(self, fits_path):
        super().__init__(fits_path)
        try:
            self._advanced_mappings()  # 可能因数据异常失败
            self.humanize_factor = 0.08  # 节奏人性化参数
            self.swing_enabled = self.data['feh'] > 0.3  # 爵士节奏开关
            self.swing_factor = 0.6 if self.data['feh'] > 0.3 else 1.0  # 爵士节奏强度
            self.jazz_harmony = JazzHarmonyGenerator(self.data)
            self._apply_jazz_settings()
        except Exception as e:
            logging.warning(f"增强映射失败: {str(e)}")
            # 设置安全默认值
            self.key = key.Key('C')
            self.spatial_pan = 0.0
            self.reverb_strength = 1.0
            print("使用默认参数")
        
    def _apply_jazz_settings(self):
        """应用爵士乐个性化设置"""
        # 根据温度设置风格
        style = PARAM_MAPPING['teff']['mapping'](self.data['teff'])
        self.swing_ratio = {
            'cool': 0.6,
            'bebop': 0.7,
            'blues': 0.65
        }.get(style, 0.67)
        
        # 设置即兴强度
        self.improv_strength = min(self.data['snr'] / 20, 0.8)
    
    def _advanced_mappings(self):
        """增强型参数映射系统"""
        # 音阶智能分析
        self._analyze_scale()
        
        # 乐器分配系统
        self.primary_instrument = self._select_primary_instrument()
        self.secondary_instrument = self._select_secondary_instrument()
        
        # 空间效果参数
        self.spatial_pan = self.data.get('RA', 0) / 180.0 - 1.0  # -1到1
        self.reverb_strength = min(self.data.get('Dec', 0) / 90.0, 1.0)

    def _analyze_scale(self):
        """音阶分析（带异常处理）"""
        try:
            dummy_melody = self._generate_base_melody()
            analyzer = discrete.KrumhanslSchmuckler()
            analyzed_key = analyzer.getSolution(dummy_melody)
            # 验证分析结果有效性
            if analyzed_key is not None:
                self.key = analyzed_key
            else:
                self.key = key.Key('C')  # 默认C大调
        except Exception as e:
            logging.warning(f"音阶分析失败: {str(e)}，使用默认C大调")
            self.key = key.Key('C')

    def _select_primary_instrument(self):
        """根据发射线分配主乐器"""
        line_strengths = {k:v for k,v in self.data['emission_lines']}
        if line_strengths.get('Hα', 0) > 500:
            return instrument.Violin()
        elif line_strengths.get('CaII', 0) > 300:
            return instrument.Trumpet()
        elif line_strengths.get('OIII', 0) > 200:
            return instrument.Flute()
        elif self.data['teff'] > 8000:
            return instrument.Celesta()
        return instrument.Piano()

    def _select_secondary_instrument(self):
        """根据logg选择次要乐器"""
        if self.data['logg'] > 4.0:
            return instrument.Marimba()
        return instrument.Contrabass()

        # 结构扩展算法 ====================================
    def generate_full_composition(self):
        """黄金分割结构扩展"""
        base_melody = self._generate_dynamic_melody().transpose(int(self.data['z']*20))
        full_score = stream.Score()
        
        # 和声层（避免平行五度）
        harmony = self._generate_harmonic_progression()
        
        # 低音层（金属丰度驱动）
        bass = self._generate_metallicity_bass()
        
        # 空间效果处理
        self._apply_spatial_effects()

        # 添加装饰音（新增方法）
        self._add_ornaments(base_melody)
    
        # 动态速度变化（基于红移参数）
        self._apply_tempo_variation()

        # 主题呈示（62%）
        exposition = base_melody.clone()
        full_score.append(exposition)
        
        # 对比段落（38%）
        contrast = base_melody.transpose(5).scaleDurations(0.8)
        full_score.append(contrast)
        
        # 再现部（62%剩余时长）
        recapitulation = base_melody.retrograde()
        full_score.append(recapitulation)
        
        return self._apply_postprocessing(full_score)

    # 辅助方法 ========================================
    def _smooth_transition(self, current, previous):
        """音程平滑处理(最大8度跳跃)"""
        if previous and abs(current.midi - previous.midi) > 8:
            candidates = [p for p in self.scale.pitches 
                        if abs(p.midi - previous.midi) <= 5]
            return random.choice(candidates) if candidates else current
        return current

    def _apply_swing(self, stream):
        """Swing节奏处理"""
        for i in range(0, len(stream)-1, 2):
            stream[i].duration *= 0.6
            stream[i+1].duration *= 1.4

    def _add_ornaments(self, melody_stream):
        """添加装饰音增强表现力"""
        for n in melody_stream.notes:
            if np.random.rand() < 0.2:  # 20%概率添加装饰
                grace = note.Note(n.pitch.transpose(1))
                grace.duration.quarterLength = 0.1
                n.addGraceNote(grace)

    def _apply_tempo_variation(self):
        """基于红移的弹性速度"""
        base_tempo = 80 * (1 + self.data['z']*0.5)
        for m in self.score.getElementsByClass('Measure'):
            m.append(tempo.MetronomeMark(
                number=base_tempo * (0.9 + 0.2*np.random.rand())))

    def _generate_dynamic_melody(self):
        """音阶约束的旋律生成"""
        melody_stream = stream.Part()
        scale_notes = self.scale.getPitches('C4', 'C6')  # 获取音阶内音高

        wl = self.data['wavelength']
        flux = self.data['flux']
        
        # 1. 计算对数归一化波长
        wl_min = np.min(wl)
        wl_max = np.max(wl)
        epsilon = 1e-8  # 防止零值
        
        # 对数归一化公式：log(wl/wl_min) / log(wl_max/wl_min)
        log_norm = np.log((wl + epsilon)/wl_min) / np.log((wl_max + epsilon)/wl_min)
        
        # 2. 非线性指数映射（可调节参数）
        exp_factor = 0.7  # 控制曲线陡峭度
        scaled_midi = 48 + 48 * (log_norm ** exp_factor)  # 48半音跨度（4个八度）
        
        # 3. 音阶约束与平滑处理
        prev_pitch = None
        for idx, midi_val in enumerate(scaled_midi):
            try:
                target = self.scale.closestPitch(pitch.Pitch(int(midi_val)))
                final_pitch = self._smooth_transition(target, prev_pitch)
            
                # 创建音符对象
                n = note.Note(final_pitch)
                n.duration = self._calculate_duration(flux[idx])
                n.volume = self._calculate_velocity(flux[idx])
            
                # 添加装饰音（10%概率）
                if np.random.rand() < 0.1:
                    self._add_ornaments(n)
            
                melody_stream.append(n)
                prev_pitch = final_pitch
                
            except Exception as e:
                logging.error(f"Error generating note: {str(e)}")
                continue
        
        return self._develop_melody(melody_stream)
    
    # 新增音阶跳跃约束方法
    def _smooth_pitch_transition(self, current_pitch, previous_pitch):
        """确保音程跳跃符合听觉美学"""
        max_interval = 8  # 最大允许半音数
        if previous_pitch is None:
            return current_pitch
        
        interval = abs(current_pitch.midi - previous_pitch.midi)
        if interval > max_interval:
            # 在音阶内寻找替代音高
            candidates = [p for p in self.scale.getPitches() 
                        if abs(p.midi - previous_pitch.midi) <= max_interval]
            if candidates:
                return random.choice(candidates)
        return current_pitch

    def _generate_harmonic_progression(self):
        """智能和声生成（带音乐理论校验）"""
        # 在方法开始处添加检查
        if not hasattr(self, 'scale'):
            self._apply_global_settings()

        chord_prog = []
        prev_chord = None
        scale_pitches = [p.midi for p in self.scale.getPitches()]  # 获取音阶MIDI数值

        def find_closest_pitch(target_pitch):
            scale_pitches = [p.midi for p in self.scale.getPitches()]
            diffs = np.abs(np.array(scale_pitches) - target_pitch.midi)
            return self.scale.getPitches()[np.argmin(diffs)]

        for seg in self._segment_spectrum():
            chord = self._create_smart_chord(seg)
            if prev_chord and not self._check_harmonic_rules(prev_chord, chord):
                chord = self._adjust_chord(prev_chord, chord)
            
            if chord.root().midi not in scale_pitches: # 添加全局音阶校验
                new_root = find_closest_pitch(chord.root())
                chord.root(new_root)
            chord_prog.append(chord)
            prev_chord = chord
        return chord_prog

    def _check_harmonic_rules(self, chord1, chord2):
        """音乐理论规则校验"""
        # 避免平行五度/八度
        """使用新版和声分析接口"""
        from music21.analysis import discrete
        analysis_result = discrete.analyzeStream([chord1, chord2], 'parallelFifths')
        return analysis_result.resultValue < 1  # 0表示无平行五度
    
    def generate_variations(self, base_melody):
        """生成音乐性变奏"""
        variations = stream.Score()
        
        # 基础变奏手法
        variation_types = [
            lambda m: m.transpose(5),              # 上移四度
            lambda m: m.augmentOrDiminish(1.5),    # 节奏扩展
            lambda m: m.retrograde(),              # 逆行
            lambda m: self._add_ornaments(m)       # 装饰音
        ]
        
        # 根据特征动态选择变奏
        if self.data['pitch_variance'] > 20:
            selected_variations = variation_types[:3]  # 大变化
        else:
            selected_variations = [variation_types[3]] # 小变化
        
        # 生成变奏
        for var_func in selected_variations:
            variations.append(var_func(base_melody))
        
        return variations
    
    def _apply_spatial_effects(self):
        """声像与音量平衡处理"""
        for i, part in enumerate(self.score.parts):
            instr = part.getInstrument()

            # 动态音量分配（主旋律 > 和声 > 节奏）
            if isinstance(instr, instrument.Violin):
                instr.volume = 100
            elif isinstance(instr, instrument.Piano):
                instr.volume = 80
            elif isinstance(instr, instrument.SnareDrum):
                instr.volume = 60

            # 声像定位（左→右分布）
            instr.pan = -1 + 2 * i / len(self.score.parts)
        
    def _generate_base_melody(self):
        """生成用于音阶分析的基准旋律"""
        base_stream = stream.Stream()
        for w in np.linspace(4000, 8000, num=20):
            midi_num = 60 + int((w - 5000) / 100 * 12)
            base_stream.append(note.Note(midi_num))
        return base_stream

    def _create_smart_chord(self, seg):
        """爵士和声引擎+声部导引"""
        root = self._calculate_chord_root(seg['wl'])
        extensions = self._get_jazz_extensions()
        
        current_chord = harmony.ChordSymbol(
            root=root,
            kind=random.choice(['maj7', '7', 'min7', 'dim7']),
            extensions=extensions
        )
        
        # 声部导引优化
        if hasattr(self, 'prev_chord'):
            current_chord = self._voice_leading(self.prev_chord, current_chord)
        self.prev_chord = current_chord
        
        return current_chord

    def _adjust_chord(self, prev_chord, current_chord):
        """和声修正（示例）"""
        return current_chord.transpose(1)  # 简单上移半音避免平行五度
    
    # 覆盖父类方法 ============================================
    def generate_rhythm(self, flux, snr):
        """改进版节奏生成：人性化+动态爵士处理"""
        rhythm_stream = stream.Part()
        rhythm_stream.append(instrument.SnareDrum())
        
        # 基于通量导数生成基础节奏型
        flux_diff = np.diff(self.data['flux'])
        window_size = int(len(flux_diff) / 32)
        variance_sequence = [np.var(flux_diff[i:i+window_size]) 
                            for i in range(0, len(flux_diff), window_size)]
        
        # 动态节奏生成
        for var in variance_sequence:
            if var > 0.1:
                note_dur = self._calculate_swing_duration(0.25)
                rhythm_stream.append(note.Note('D2', quarterLength=note_dur))
            else:
                rhythm_stream.append(note.Rest(quarterLength=0.5))
        
        # 后处理：人性化与风格化
        self._humanize_rhythm(rhythm_stream)
        if self.swing_factor < 1.0:
            self._apply_swing_effect(rhythm_stream)
        
        return rhythm_stream

    # 动态参数映射示例
    def _calculate_swing_duration(self, base_dur):
        """动态计算Swing时值"""
        swing_ratio = 0.6 + 0.2 * (self.data['feh'] - 0.3)  # Fe/H∈[0.3,0.8] → ratio∈[0.6,0.8]
        return base_dur * swing_ratio

    def generate_harmony(self, wavelength, flux):
        """改进版和声生成：爵士扩展+声部导引"""
        chord_progression = []
        peak_indices = self._find_flux_peaks(flux)
        
        # 动态和弦生成逻辑
        for i in range(len(peak_indices)-1):
            seg_flux = flux[peak_indices[i]:peak_indices[i+1]]
            seg_wl = wavelength[peak_indices[i]:peak_indices[i+1]]
            
            # 和弦复杂度计算
            tension_score = np.var(seg_wl) * np.mean(seg_flux)
            chord_type = self._select_chord_type(tension_score)
            
            # 生成扩展和弦
            jazz_chord = self._build_jazz_chord(
                root_freq=np.median(seg_wl),
                chord_type=chord_type,
                metalicity=self.data['feh']
            )
            chord_progression.append(jazz_chord)
        
        return self._optimize_voice_leading(chord_progression)

    # 新增核心方法 ============================================
    def _humanize_rhythm(self, rhythm_stream):
        """精确的人性化节奏处理"""
        self.humanize_range = 0.1 + 0.05 * self.data['z']  # 红移影响人性化程度
        for n in rhythm_stream.notes:
            rand_offset = (np.random.rand() - 0.5) * self.humanize_range
            n.offset += rand_offset  # 时间偏移
            
            # 时值扰动 (±15% 原始时值)
            original_dur = n.duration.quarterLength
            new_dur = original_dur * (0.85 + np.random.rand()*0.3)
            n.duration.quarterLength = max(new_dur, 0.1)  # 确保最小时值

    def _apply_swing_effect(self, stream):
        """精确的Swing节奏实现"""
        notes = list(stream.notes)
        for i in range(0, len(notes)-1, 2):
            # 获取音符对象引用
            first_note = notes[i]
            second_note = notes[i+1] if (i+1) < len(notes) else None
            
            if second_note:  # 仅处理完整的两音组
                # 调整时长比例 (2:1 → 3:1)
                total_dur = first_note.duration.quarterLength + second_note.duration.quarterLength
                first_note.duration.quarterLength = total_dur * 0.75
                second_note.duration.quarterLength = total_dur * 0.25
                
                # 动态表情控制
                first_note.volume.velocity = int(first_note.volume.velocity * 0.85)
                second_note.expressions.append(expressions.Accent())
                second_note.volume.velocity = min(int(second_note.volume.velocity * 1.2), 127)

    def _build_jazz_chord(self, root_freq, chord_type, metalicity):
        """构造爵士和弦"""
        # 频率→音高映射
        root_pitch = pitch.Pitch()
        root_pitch.frequency = root_freq
        root_pitch = self.scale.closestPitch(root_pitch)
        
        # 和弦结构定义
        chord_map = {
            'maj7': [0, 4, 7, 11],
            '7': [0, 4, 7, 10],
            'min7': [0, 3, 7, 10],
            'm7b5': [0, 3, 6, 10],
            'alt': [0, 4, 8, 10]
        }
        intervals = chord_map.get(chord_type, [0,4,7])
        
        # 添加扩展音（基于金属丰度）
        if metalicity > 0.5:
            extensions = [14, 17]  # 9th和13th
            if np.random.rand() < 0.3:
                extensions += [15]  # #11
            intervals += extensions
        
        return chord.Chord([root_pitch.transpose(i) for i in intervals])

    def _build_jazz_chord(self, root_freq, chord_type, metalicity):
        """精确的爵士和弦构造"""
        # 频率→音高转换
        root_pitch = pitch.Pitch()
        root_pitch.frequency = root_freq
        root_pitch = self.scale.closestPitch(root_pitch)
        
        # 和弦结构定义（半音偏移）
        intervals = {
            'maj7': [0,4,7,11],
            '7': [0,4,7,10],
            'min7': [0,3,7,10],
            'alt': [0,4,8,10,15]
        }[chord_type]
        
        # 金属丰度控制扩展音
        if metalicity > 0.5:
            intervals += [14,17]  # 添加9th和13th
            if chord_type == 'alt':
                intervals += [15]  # 添加#11音
        
        return chord.Chord([root_pitch.transpose(i) for i in intervals])

    # 辅助方法 ================================================
    def _savgol_filter(self, y, window_size, order):
        """封装的滤波方法"""
        from scipy.signal import savgol_filter
        return savgol_filter(y, window_size, order, mode='nearest')

    def _savitzky_golay(self, y, window_size, order):
        """平滑滤波算法"""
        from scipy.signal import savgol_filter
        return savgol_filter(y, window_size, order)
    
    def _select_chord_type(self, tension_score):
        """动态选择和弦类型"""
        if self.data['feh'] > 0.5:
            return random.choices(['maj7', '7', 'min7', 'alt'], 
                                weights=[0.3,0.4,0.2,0.1])[0]
        return 'major' if tension_score > 0.15 else 'minor'

    def _optimize_voice_leading(self, progression):
        """优化声部进行，避免平行五八度"""
        optimized = []
        prev_chord = None
        for chord in progression:
            if prev_chord:
                new_notes = []
                for prev_note, curr_note in zip(prev_chord.notes, chord.notes):
                    interval = interval.Interval(prev_note, curr_note)
                    if interval.name in ['P5', 'P8']:
                        # 向上三度替代
                        new_note = curr_note.transpose(3)
                        new_notes.append(new_note)
                    else:
                        new_notes.append(curr_note)
                chord = chord.Chord(new_notes)
            optimized.append(chord)
            prev_chord = chord
        return optimized

    def _find_flux_peaks(self, flux):
        """改进的峰值检测"""
        from scipy.signal import find_peaks, savgol_filter
        
        # 预处理：Savitzky-Golay滤波
        smoothed = savgol_filter(flux, 
                                window_length=11, 
                                polyorder=3,
                                mode='nearest')
        
        # 动态峰值检测
        peaks, _ = find_peaks(smoothed, 
                            prominence=np.std(flux)*0.5,
                            width=5)
        return peaks

    def _calculate_chord_root(self, wavelength_segment):
        """和弦根音计算（基于波长中值）"""
        median_wl = np.median(wavelength_segment)
        root_pitch = pitch.Pitch()
        root_pitch.frequency = 1e8/median_wl  # 波长→频率转换
        return self.scale.closestPitch(root_pitch)

    def _get_jazz_extensions(self):
        """动态爵士扩展音生成"""
        extensions = []
        if self.data['feh'] > 0.5:
            extensions += ['9', '13']
            if np.random.rand() < 0.4:
                extensions += ['#11']
        return extensions

    def _check_harmonic_rules(self, chord1, chord2):
        """和声规则检查(使用新版music21接口)"""
        from music21.analysis import windowedHarmony
        analyzer = windowedHarmony.WindowedHarmony()
        analyzer.setWindowSize(2)
        analyzer.process([chord1, chord2])
        return analyzer.resultValue('parallelFifths') < 1

    def _calculate_duration(self, flux_value):
        """动态时值计算"""
        base_dur = 0.25 + (flux_value / np.max(self.data['flux'])) * 2
        return min(max(base_dur, 0.125), 4.0)  # 限制在32分音符到全音符之间

    def _calculate_velocity(self, flux_value):
        """动态力度计算"""
        return int(40 + 87 * (flux_value ** 0.5))

    def _develop_melody(self, base_melody):
        """旋律发展算法"""
        developed = stream.Stream()
        
        # 原始主题
        developed.append(base_melody.clone())
        
        # 倒影变奏
        inverted = base_melody.chordify().transpose(-5)
        developed.append(inverted.scaleDurations(0.8))
        
        # 逆行扩展
        retro = base_melody.retrograde()
        developed.append(retro.transpose(2))
        
        return developed

    # 装饰音处理方法
    def _add_grace_note(self, main_note):
        """添加装饰音"""
        grace = main_note.clone()
        grace.duration.quarterLength = 0.1
        grace.pitch = grace.pitch.transpose(1)
        main_note.addGraceNote(grace)

    # 后处理流程
    def _apply_postprocessing(self, score):
        """综合后处理"""
        # 动态平衡
        for part in score.parts:
            self._normalize_volumes(part)
        
        # 添加全局效果
        score.insert(0, dynamics.Dynamic('mf'))
        return score

    def _normalize_volumes(self, stream):
        """音量标准化"""
        velocities = [n.volume.velocity for n in stream.notes if hasattr(n, 'volume')]
        if velocities:
            max_vel = max(velocities)
            for n in stream.notes:
                n.volume.velocity = int(n.volume.velocity / max_vel * 120)