---
title: Thoughts on Re-Encoded BD Animes
description: My opinions on anime video/audio encoding and audio track optimization.
slug: thoughts-on-re-encoded-bd-animes
date: 2023-01-17 21:28:00+0800
categories:
    - audio
    - anime
    - encoding
tags:
    - anime
    - audio
    - encoding
---

## Introduction

Re-encoded BD anime series are my go-to when watching animes. They have great quality while being a fraction of the size of a Blu-ray disc. Let alone they come with all kinds of extra contents.

Nowadays, re-encoded BD anime series usually have video tracks compressed using 10-bit x265 (a software implementation of the H.265/HEVC video compression standard), and audio tracks compressed using FLAC (a lossless audio codec).

The video tracks are great, generally a good balance between size and quality, no complaints. The audio tracks are my main problem. Sometimes they take up too much space with no real benefit for most viewers.

> Other versions like WEB-DL are not considered because they are already heavily compressed so they don't have the space concerns.

## Video Tracks

I am totally satisfied with the video tracks, because:

1. the x265 encoder is very efficient (especially at variable bitrate controlling, which most hardware encoders still suffer from, i.e. NVIDIA NVENC, Intel QuickSync, and AMD VCN), being able to compress video to a fraction of the size of the BD original while preserving video quality;
2. the encoding team usually does a great job doing manual optimizations to fix problems in the original video, such as aliasing, ringing, and color banding. (Some team even goes as far as AI upscaling the video, although a bit controversial.)

Despite being one third (or even less) of the original bitrate, you can barely tell the difference between the re-encoded video and the original one, even when comparing side-by-side. In fact, the re-encoded video is sometimes even better due to the manual optimizations by the encoding team. This saves a lot of space while preserving video quality.

> Video encoding is a complex topic, involving a huge amount of trial and error, even x265-encoding alone has a TON of dials and knobs to tweak, and this is only part of the whole encoding process. I will not go into details here, simply because of my lack of knowledge.

### Samples

For example, you can see what the encoding team (VCB-Studio) does to optimize the original video quality from the note of *Haiyore! Nyaruko-san / 潜行吧！奈亚子* :

> For Season 1, the source is of nothing special. Its native resolution is 720p, then upscaled by a poor algorithm. This leads to many defects: lines featuring severe aliasing and ringing as well as serious ringing on the image borders. Dark scenes are widely spread throughout Season 1, together with the plentiful use of dark fades, resulting in heavy colour banding.
> For the lines, most of the problems can be solved by descaling and reconstruction, then slight AA and moderate de-ringing as supplements. For colour banding, since most scenes have only a little colour banding, in order to deal with severe colour banding in dark scenes, we designed a complex mask for protection in combination with luminance information. We also use a colour banding detection algorithm. Thanks to all those, we finally adaptively controlled the strength of de-banding. At the end, we added some grains to improve the viewing exprience.
> 
> 第一季原盘画质一般。原生分辨率为 720p，被比较劣质的算法拉升上来，导致线条带有严重锯齿和振铃，而且画面的边框部分有很强的拉升带来的边缘振铃。画面暗场极多，而且大量运用暗式淡入淡出，这些场景出现了严重的色带。
> 对于线条，大部分问题都可以通过逆向拉升再重构解决，然后补上轻微的抗锯齿处理和中等强度的去振铃处理。对于色带，由于大部分场景的色带都很少，只有少部分暗场有较严重的色带，我们结合亮度信息设计了复杂的保护手段，并使用了一个色带检测算法，根据检测的结果对去色带的力度进行了自适应调整。最后加上了一定强度的动态噪点，以改善原盘噪点的观感。

<details>
<summary>MediaInfo: Haiyore! Nyaruko-san episode 1 from VCB-Studio</summary>

```
General
Unique ID                                : 276260962046491867529669363000855506406 (0xCFD5ED098E39DF78A31330DA2C4C2DE6)
Complete name                            : /Volumes/pool-raidz-3x4tb-0/public/anime/[VCB-Studio] Haiyore! Nyaruko-san/[VCB-Studio] Haiyore! Nyaruko-san [Ma10p_1080p]/[VCB-Studio] Haiyore! Nyaruko-san [01][Ma10p_1080p][x265_flac].mkv
Format                                   : Matroska
Format version                           : Version 4
File size                                : 946 MiB
Duration                                 : 23 min 56 s
Overall bit rate mode                    : Variable
Overall bit rate                         : 5 524 kb/s
Encoded date                             : UTC 2022-05-28 10:09:48
Writing application                      : mkvmerge v48.0.0 ('Fortress Around Your Heart') 64-bit
Writing library                          : libebml v1.4.0 + libmatroska v1.6.0

Video
ID                                       : 1
Format                                   : HEVC
Format/Info                              : High Efficiency Video Coding
Format profile                           : Main 10@L4.1@High
Codec ID                                 : V_MPEGH/ISO/HEVC
Duration                                 : 23 min 56 s
Bit rate                                 : 4 028 kb/s
Width                                    : 1 920 pixels
Height                                   : 1 080 pixels
Display aspect ratio                     : 16:9
Frame rate mode                          : Constant
Frame rate                               : 23.976 (24000/1001) FPS
Color space                              : YUV
Chroma subsampling                       : 4:2:0
Bit depth                                : 10 bits
Bits/(Pixel*Frame)                       : 0.081
Stream size                              : 690 MiB (73%)
Writing library                          : x265 3.5+97-ga456c6e73+1-g9859a8cb5:[Windows][clang 14.0.0][64 bit] Kyouko 10bit+8bit+12bit
Encoding settings                        : rc=crf / crf=14.0000 / qcomp=0.65 / qpstep=4 / stats-write=0 / stats-read=0 / vbv-maxrate=38000 / vbv-bufsize=40000 / vbv-init=0.9 / min-vbv-fullness=50.0 / max-vbv-fullness=80.0 / crf-max=0.0 / crf-min=0.0 / no-lossless / no-cu-lossless / aq-mode=3 / aq-strength=1.00 / aq-bias-strength=1.00 / cbqpoffs=-2 / crqpoffs=-2 / ipratio=1.40 / pbratio=1.20 / psy-rd=2.00 / psy-rdoq=1.00 / deblock=-1:-1 / ref=5 / limit-refs=0 / no-limit-modes / bframes=10 / b-adapt=2 / bframe-bias=0 / b-pyramid / b-intra / weightp / weightb / min-keyint=1 / max-keyint=360 / rc-lookahead=80 / gop-lookahead=0 / scenecut=40 / hist-scenecut=0 / radl=0 / max-cu-size=32 / min-cu-size=8 / me=3 / subme=5 / merange=38 / rdoq-level=1 / rd=5 / rdpenalty=0 / dynamic-rd=0.00 / rd-refine / ----- / cutree / no-sao / rect / no-amp / no-open-gop / wpp / no-pmode / no-pme / no-psnr / no-ssim / nr-intra=0 / nr-inter=0 / no-constrained-intra / no-strong-intra-smoothing / max-tu-size=16 / tu-inter-depth=4 / tu-intra-depth=4 / limit-tu=0 / qg-size=32 / qpmax=69 / qpmin=0 / ----- / cpuid=1111039 / frame-threads=4 / numa-pools=+ / log-level=2 / input-csp=1 / input-res=1920x1080 / interlace=0 / level-idc=0 / high-tier=1 / uhd-bd=0 / no-allow-non-conformance / no-repeat-headers / no-aud / no-hrd / info / hash=0 / no-temporal-layers / lookahead-slices=0 / no-splice / no-intra-refresh / no-ssim-rd / signhide / tskip / max-merge=5 / temporal-mvp / no-frame-dup / no-hme / no-analyze-src-pics / no-sao-non-deblock / selective-sao=0 / no-early-skip / no-rskip / no-fast-intra / no-tskip-fast / no-splitrd-skip / zone-count=0 / no-strict-cbr / no-rc-grain / no-const-vbv / sar=0 / overscan=0 / videoformat=5 / range=0 / colorprim=1 / transfer=1 / colormatrix=1 / chromaloc=0 / display-window=0 / cll=0,0 / min-luma=0 / max-luma=1023 / log2-max-poc-lsb=8 / vui-timing-info / vui-hrd-info / slices=1 / no-opt-qp-pps / no-opt-ref-list-length-pps / no-multi-pass-opt-rps / scenecut-bias=0.05 / hist-threshold=0.03 / no-opt-cu-delta-qp / no-aq-motion / no-hdr10 / no-hdr10-opt / no-dhdr10-opt / no-idr-recovery-sei / analysis-reuse-level=0 / analysis-save-reuse-level=0 / analysis-load-reuse-level=0 / scale-factor=0 / refine-intra=0 / refine-inter=0 / refine-mv=1 / refine-ctu-distortion=0 / no-limit-sao / ctu-info=0 / no-lowpass-dct / refine-analysis-type=0 / copy-pic=1 / max-ausize-factor=1.0 / no-dynamic-refine / no-single-sei / no-hevc-aq / no-svt / no-field / qp-adaptation-range=1.00 / scenecut-aware-qp=0conformance-window-offsets / right=0 / bottom=0 / decoder-max-rate=0 / no-vbv-live-multi-pass
Default                                  : Yes
Forced                                   : No
Color range                              : Limited
Color primaries                          : BT.709
Transfer characteristics                 : BT.709
Matrix coefficients                      : BT.709

Audio
ID                                       : 2
Format                                   : FLAC
Format/Info                              : Free Lossless Audio Codec
Codec ID                                 : A_FLAC
Duration                                 : 23 min 56 s
Bit rate mode                            : Variable
Bit rate                                 : 1 494 kb/s
Channel(s)                               : 2 channels
Channel layout                           : L R
Sampling rate                            : 48.0 kHz
Frame rate                               : 11.719 FPS (4096 SPF)
Bit depth                                : 24 bits
Compression mode                         : Lossless
Stream size                              : 256 MiB (27%)
Writing library                          : libFLAC 1.3.2 (UTC 2017-01-01)
Language                                 : Japanese
Default                                  : Yes
Forced                                   : No

Menu
00:00:00.000                             : en:Chapter 01
00:01:14.992                             : en:Chapter 02
00:02:45.040                             : en:Chapter 03
00:13:08.997                             : en:Chapter 04
00:22:10.037                             : en:Chapter 05
00:23:40.002                             : en:Chapter 06
```
</details>

As of video quality, you can verify yourself. Here are some frames extracted from *Haiyore! Nyaruko-san / 潜行吧！奈亚子* (VCB-Studio). Can you tell any difference between the original and the re-encoded video? Remember that the re-encoded video has a bitrate of only 4028 kbps, while the original video will *at least* triple that.

> This blog uses Responsive Images to improve experience, so what you see here may be scaled down. To view the original image, you can download the original file from the links provided.

| Original                       | Re-encoded                        |
| ------------------------------ | --------------------------------- |
| ![original-0](images/13414.png) [original-0](images/13414.png) | ![re-encoded-0](images/13414v.png) [re-encoded-0](images/13414v.png) |
| ![original-1](images/22040.png) [original-1](images/22040.png) | ![re-encoded-1](images/22040v.png) [re-encoded-1](images/22040v.png) |
| ![original-2](images/998.png) [original-2](images/998.png) | ![re-encoded-2](images/998v.png) [re-encoded-2](images/998v.png) |
| ![original-3](images/19267.png) [original-3](images/19267.png) | ![re-encoded-3](images/19267v.png) [re-encoded-3](images/19267v.png) |

> Can't notice any difference? Or the re-encoded one look better? Save the image locally and zoom in further :p. Yes, I DO put the correct pictures in the correct places.

The static images are already hard to tell apart. The difference will be even smaller when you are watching the video, simply because there are motions in the video and you will not be able to focus on the details. 

So yeah, the video tracks are great. I will not touch them.

## Audio Tracks

### Lossless Compression Problem

However, the audio part is where I have a problem. It's not about quality, but about size. Let me explain.

Unlike the video tracks, which is compressed using a lossy codec (H.265/HEVC), the audio tracks are usually losslessly compressed, which means that its quality is 100% same to the original, literally. This is great for archival purposes, but it's a overkill for most people. Because what comes with great quality is size. FLAC tracks usually have a bitrate of 1000+ kbps. One FLAC track in a single episode will typically be over 200 MB in size, as you can seen from the example below. By compressing them to 200 kbps, for example, you save 800+ kbps per track, or put it simply, cut a 200 MB track to 40 MB, which saves a lot of space. This is especially true for animes with multiple FLAC tracks. An extreme example is *Kobayashi-san Chi no Maidragon / Miss Kobayachi's Dragon Maid / 小林家的龙女仆* from team AI-Raws. It has three FLAC tracks, with a total bitrate of 3955 (1432+1294+1229) kbps. Compressing them to 600 (200*3) kbps will cut the entire episode size from 1.89 GB to 1.3 GB, which is a 36% reduction in size, saving 400 MB per episode. That's a lot.

<details>
<summary>MediaInfo: Kobayashi-san Chi no Maidragon episode 1 from AI-Raws</summary>

```
General
Unique ID                                : 39274225615593709220200463866578723060 (0x1D8BF0D2BC4C9D643B9E040209C9E0F4)
Complete name                            : /Volumes/pool-raidz-3x4tb-0/public/anime/[AI-Raws][Miss Kobayachi's Dragon Maid][BDRip][MKV]/[AI-Raws] 小林さんちのメイドラゴン #01 (BD HEVC 1920x1080 yuv444p10le FLAC 日本語字幕)[6FDC51A9].mkv
Format                                   : Matroska
Format version                           : Version 4
File size                                : 1.89 GiB
Duration                                 : 25 min 11 s
Overall bit rate mode                    : Variable
Overall bit rate                         : 10.8 Mb/s
Encoded date                             : UTC 2022-01-24 14:17:11
Writing application                      : mkvmerge v33.1.0 ('Primrose') 64-bit
Writing library                          : libebml v1.3.7 + libmatroska v1.5.0

Video
ID                                       : 1
Format                                   : HEVC
Format/Info                              : High Efficiency Video Coding
Format profile                           : Format Range@L4@High
Codec ID                                 : V_MPEGH/ISO/HEVC
Duration                                 : 25 min 11 s
Bit rate                                 : 6 700 kb/s
Width                                    : 1 920 pixels
Height                                   : 1 080 pixels
Display aspect ratio                     : 16:9
Frame rate mode                          : Constant
Frame rate                               : 23.976 (24000/1001) FPS
Chroma subsampling                       : 4:4:4
Bit depth                                : 10 bits
Bits/(Pixel*Frame)                       : 0.135
Stream size                              : 1.18 GiB (62%)
Writing library                          : x265 2.9+8-27d8424c799d:[Windows][MSVC 1900][64 bit] 10bit
Encoding settings                        : cpuid=1111039 / frame-threads=4 / numa-pools=16 / wpp / no-pmode / no-pme / no-psnr / no-ssim / log-level=2 / input-csp=3 / input-res=1920x1080 / interlace=0 / total-frames=0 / level-idc=0 / high-tier=1 / uhd-bd=0 / ref=4 / no-allow-non-conformance / no-repeat-headers / annexb / no-aud / no-hrd / info / hash=0 / no-temporal-layers / open-gop / min-keyint=23 / keyint=250 / gop-lookahead=0 / bframes=4 / b-adapt=2 / b-pyramid / bframe-bias=0 / rc-lookahead=25 / lookahead-slices=4 / scenecut=40 / radl=0 / no-intra-refresh / ctu=64 / min-cu-size=8 / rect / no-amp / max-tu-size=32 / tu-inter-depth=1 / tu-intra-depth=1 / limit-tu=0 / rdoq-level=2 / dynamic-rd=0.00 / no-ssim-rd / signhide / no-tskip / nr-intra=0 / nr-inter=0 / no-constrained-intra / strong-intra-smoothing / max-merge=3 / limit-refs=3 / limit-modes / me=3 / subme=3 / merange=57 / temporal-mvp / weightp / no-weightb / no-analyze-src-pics / deblock=0:0 / sao / no-sao-non-deblock / rd=4 / no-early-skip / rskip / no-fast-intra / no-tskip-fast / no-cu-lossless / no-b-intra / no-splitrd-skip / rdpenalty=0 / psy-rd=2.00 / psy-rdoq=1.00 / no-rd-refine / no-lossless / cbqpoffs=6 / crqpoffs=6 / rc=crf / crf=14.5 / qcomp=0.60 / qpstep=4 / stats-write=0 / stats-read=0 / vbv-maxrate=25600 / vbv-bufsize=10240 / vbv-init=0.9 / crf-max=0.0 / crf-min=0.0 / ipratio=1.40 / pbratio=1.30 / aq-mode=1 / aq-strength=1.00 / cutree / zone-count=0 / no-strict-cbr / qg-size=32 / no-rc-grain / qpmax=31 / qpmin=0 / no-const-vbv / sar=0 / overscan=0 / videoformat=5 / range=0 / colorprim=1 / transfer=2 / colormatrix=2 / chromaloc=0 / display-window=0 / max-cll=0,0 / min-luma=0 / max-luma=1023 / log2-max-poc-lsb=8 / vui-timing-info / vui-hrd-info / slices=1 / no-opt-qp-pps / no-opt-ref-list-length-pps / no-multi-pass-opt-rps / scenecut-bias=0.05 / no-opt-cu-delta-qp / no-aq-motion / no-hdr / no-hdr-opt / no-dhdr10-opt / no-idr-recovery-sei / analysis-reuse-level=5 / scale-factor=0 / refine-intra=0 / refine-inter=0 / refine-mv=0 / no-limit-sao / ctu-info=0 / no-lowpass-dct / refine-mv-type=0 / copy-pic=1 / max-ausize-factor=1.0 / no-dynamic-refine / no-single-sei
Default                                  : Yes
Forced                                   : No
Color range                              : Limited
Color primaries                          : BT.709

Audio #1
ID                                       : 2
Format                                   : FLAC
Format/Info                              : Free Lossless Audio Codec
Codec ID                                 : A_FLAC
Duration                                 : 25 min 11 s
Bit rate mode                            : Variable
Bit rate                                 : 1 432 kb/s
Channel(s)                               : 2 channels
Channel layout                           : L R
Sampling rate                            : 48.0 kHz
Frame rate                               : 11.719 FPS (4096 SPF)
Bit depth                                : 24 bits
Compression mode                         : Lossless
Stream size                              : 258 MiB (13%)
Writing library                          : libFLAC 1.2.1 (UTC 2007-09-17)
Default                                  : Yes
Forced                                   : No

Audio #2
ID                                       : 3
Format                                   : FLAC
Format/Info                              : Free Lossless Audio Codec
Codec ID                                 : A_FLAC
Duration                                 : 25 min 11 s
Bit rate mode                            : Variable
Bit rate                                 : 1 294 kb/s
Channel(s)                               : 2 channels
Channel layout                           : L R
Sampling rate                            : 48.0 kHz
Frame rate                               : 11.719 FPS (4096 SPF)
Bit depth                                : 24 bits
Compression mode                         : Lossless
Stream size                              : 233 MiB (12%)
Title                                    : キャストコメンタリー
Writing library                          : libFLAC 1.2.1 (UTC 2007-09-17)
Default                                  : No
Forced                                   : No

Audio #3
ID                                       : 4
Format                                   : FLAC
Format/Info                              : Free Lossless Audio Codec
Codec ID                                 : A_FLAC
Duration                                 : 25 min 11 s
Bit rate mode                            : Variable
Bit rate                                 : 1 229 kb/s
Channel(s)                               : 2 channels
Channel layout                           : L R
Sampling rate                            : 48.0 kHz
Frame rate                               : 11.719 FPS (4096 SPF)
Bit depth                                : 24 bits
Compression mode                         : Lossless
Stream size                              : 221 MiB (11%)
Title                                    : スタッフコメンタリー
Writing library                          : libFLAC 1.2.1 (UTC 2007-09-17)
Default                                  : No
Forced                                   : No

Text
ID                                       : 5
Format                                   : PGS
Muxing mode                              : zlib
Codec ID                                 : S_HDMV/PGS
Codec ID/Info                            : Picture based subtitle format used on BDs/HD-DVDs
Duration                                 : 24 min 30 s
Bit rate                                 : 277 kb/s
Count of elements                        : 2364
Stream size                              : 48.5 MiB (3%)
Language                                 : Japanese
Default                                  : Yes
Forced                                   : No
```
</details>

### Lossy Compression

But compressing them so hard will certainly bring quality losses... Or will it? Well, yes, there must be quality loss when using lossy codecs, but the question is how much? Is it acceptable? You have seen that the example video tracks are compressed to 4028 kbps, which is a lot less than the original video. But the video tracks are still great. So, is the quality loss acceptable for audio tracks?

In fact, using a modern codec at 256 kbps (or even half that), the quality loss is so little that I can almost guarantee that you will NOT hear a difference for two reasons:

1. most codecs are considered "transparent" at 256 kbps or above (better codes will be "transparent" at even lower bitrate), which means that you cannot tell the difference between the original and the compressed one (more on this later);
2. when watching anime, you are usually not paying attention to details in the audio, but the video. This makes the difference in audio tracks even less noticeable.

So we can safely compress audio without worrying about quality loss. But how much should we compress? Well, that depends on your own preference. Generally, you can choose a codec and a bitrate that is better than what is "transparent" to you.

But hold on, how do I know what is "transparent" to me?

### Audio Transparency

There is a concept called "transparent" in audio encoding, which means the compressed audio is so good that a person cannot tell a difference between the original and the compressed one. This is usually done through ABX blind tests, where the listener is not told which one is the original and which one is the compressed one. If the listener cannot tell the difference, then the audio is considered transparent. Of course, this differs from person to person. You have to do the test with your own ears with different encoders at different bitrates to find your "transparent" threshold (which codec at which bitrate). When you find your threshold, any better codec at any better bitrate will also be transparent to you.

> About Bitrate and quality:
> 
> They cannot be compared directly. For example, 320 kbps MP3 is not the same as 320 kbps AAC. (AAC is generally considered a better codec than MP3, so it can achieve the same quality with a lower bitrate.)
> 
> - When dealing with the same codec (same encoder, same settings), the higher the bitrate, the better the quality. For example, MP3 at 320 kbps wll have better quality than MP3 at 256 kbps.
> 
> - But when dealing with different codecs, the bitrate is not the only factor that affects the quality. The codec itself, the encoder, encoding settings, and etc. all affect quality. For example, AAC (qaac, vbr, default settings) at 256 kbps is often said to have similar quality to MP3 at 320 kbps.

But the general consensus is that Opus is transparent at 160kbps and above, and AAC is transparent at 192kbps and above:

- A [blind test of multiple codecs at ~192kbps VBR](https://hydrogenaud.io/index.php?topic=120007.0) shows that codecs at 192k is transparent to the test subject. Opus being the most transparent codec at 192k;

  > ![blind test – MultiCodec at ~192 VBR kbps](images/IgorC_192kbps1enc.png)

- Tests of different encoders at different bitrates published by SoundExpert show that most codecs at 128kbps and above are transparent to most test subjects. Detailed results can be found at http://soundexpert.org/encoders-128-kbps;

- [A topic from HydrogenAudio forum](https://hydrogenaud.io/index.php/topic,114656.0.html) even shows that Opus at ~80kbps is transparent to an average listener;

  > It's interesting to observe that 4 members have mentioned Opus@80kbps as point where is hard to spot artifacts for them.
  > 
  > Opus ~80 kbps is roughly equivalent to LAME ~130 kbps (V5) which lands in an "excellent" area of quality (MOS 4.5+) http://listening-tests.hydrogenaud.io/sebastian/mp3-128-1/results.htm
  >
  > So one could say that Opus 80 kbps is "excellent" at least for *an average listener.* It's clear that an experienced listeners can spot artifacts at much higher rates.
  >
  > > I never noticed any artifacts at 80kbps though, though I haven't tried to find any either. [Quote from: noiselab on 2017-09-18 06:49:15](https://hydrogenaud.io/index.php?msg=945143)
  >
  > > I tried it and for me it's 80 kbit. [Quote from: hlloyge on 2017-09-18 11:49:01](https://hydrogenaud.io/index.php?msg=945153)
  > 
  > > I'll be honest, I struggled to ABX at 64kbps. 80kbps is enough for me. [Quote from: Funkstar De Luxe on 2017-09-18 13:35:01](https://hydrogenaud.io/index.php?msg=945154)
  >
  > > 80kbps is pretty much my limit as well, can't be bothered listening to killer samples all the time. [Quote from: bstrobl on 2017-09-18 14:39:30](https://hydrogenaud.io/index.php?msg=945156)

- All iTunes music is delivered in AAC at 256kbps (before the arrival of Apple Music Lossless), which is an indication that most people cannot tell the difference as Apple is a company that cares about quality;

As you can see I am only focusing on AAC and Opus (as of lossy codecs), because AAC offers good sound quality and great compatibility while Opus has great sound quality and "okay" compatibility. Other codecs like MP3 are just not good enough to compete with them, so they will not be my choice later.

### Listening Samples

Now bring your best audio equipment. Same as before, let's listen to some samples to see if you can tell a difference, or you can do blind ABX tests by yourself to find your "transparent" threshold.

All lossy codecs are encoded using VBR (CBR is not considered because it is not size-efficient) with a quality setting to match the resulting bitrates of different encoders as close as possible.

<details>
<summary>Encoder versions</summary>

```
opusenc 0.2-3-gf5f571b; libopus 1.3.1
OggEnc v2.88; libvorbis 1.3.6
qaac 2.73; CoreAudioToolbox 7.10.9.0
lame 3.100
```
</details>

> Note that if you cannot playback some audio tracks, make sure your browser supports this type of audio or you can download the audio tracks and play them locally. Latest versions of Chromium-based browsers should be fine. Safari might have some issues with Opus and Ogg.

#### Orange / オレンジ

For the first example, I will use *Orange / オレンジ* by 7!! --- the 2nd ending song from *Shigatsu wa Kimi no Uso / 四月は君の嘘 / Your Lie in April / 四月是你的谎言* for its female voices. The audio is not complex (simpley put, do not contain many instruments), so it is easier for the encoders to achieve good results.

##### Vocal

Reference track:

<figure>
<figcaption>flac, best, 893k</figcaption>
<audio 
style="margin:0 24px 0 24px;" 
controls loop preload="none" 
type="audio/flac" 
src="media/orange-0-flac-893k.flac" />
</figure>

Compressed tracks:

| VBR Bitrate | Opus | AAC | Ogg | MP3 |
| ----------- | ---- | --- | --- | --- |
| ~256k | <figure><figcaption>opusenc, vbr256, 276k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-opus-vbr256k-276k.opus" /></figure> | <figure><figcaption>qaac, q109, 225k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-0-qaac-q109-225k.m4a" /></figure> | <figure><figcaption>oggenc2, q8, 234k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-vorbis-q8-234k.ogg" /></figure> | <figure><figcaption>lame, v0, 249k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-0-lame-v0-249k.mp3" /></figure> | 
| ~192k | <figure><figcaption>opusenc, vbr192, 212k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-opus-vbr192k-212k.opus" /></figure> | <figure><figcaption>qaac, q91, 171k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-0-qaac-q91-171k.m4a" /></figure> | <figure><figcaption>oggenc2, q6, 178k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-vorbis-q6-178k.ogg" /></figure> | <figure><figcaption>lame, v2, 182k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-0-lame-v2-182k.mp3" /></figure> | 
| ~160k | <figure><figcaption>opusenc, vbr160, 180k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-opus-vbr160k-180k.opus" /></figure> | <figure><figcaption>qaac, q82, 142k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-0-qaac-q82-142k.m4a" /></figure> | <figure><figcaption>oggenc2, q5, 153k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-vorbis-q5-153k.ogg" /></figure> | <figure><figcaption>lame, v4, 148k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-0-lame-v4-148k.mp3" /></figure> | 
| ~128k | <figure><figcaption>opusenc, vbr128, 146k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-opus-vbr128k-146k.opus" /></figure> | <figure><figcaption>qaac, q64, 113k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-0-qaac-q64-113k.m4a" /></figure> | <figure><figcaption>oggenc2, q4, 131k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-vorbis-q4-131k.ogg" /></figure> | <figure><figcaption>lame, v5, 126k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-0-lame-v5-126k.mp3" /></figure> | 
| ~96k | <figure><figcaption>opusenc, vbr96, 111k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-opus-vbr96k-111k.opus" /></figure> | <figure><figcaption>qaac, q45, 86k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-0-qaac-q45-86k.m4a" /></figure> | <figure><figcaption>oggenc2, q2, 92k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-vorbis-q2-92k.ogg" /></figure> | <figure><figcaption>lame, v7, 98k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-0-lame-v7-98k.mp3" /></figure> | 
| ~64k | <figure><figcaption>opusenc, vbr64, 76k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-opus-vbr64k-76k.opus" /></figure> | <figure><figcaption>qaac, q27, 66k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-0-qaac-q27-66k.m4a" /></figure> | <figure><figcaption>oggenc2, q0, 61k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-0-vorbis-q0-61k.ogg" /></figure> | <figure><figcaption>lame, v9, 69k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-0-lame-v9-69k.mp3" /></figure> | 

##### Vocal with simple instruments

Reference track:

<figure>
<figcaption>flac, best, 920k</figcaption>
<audio 
style="margin:0 24px 0 24px;" 
controls loop preload="none" 
type="audio/flac" 
src="media/orange-1-flac-920k.flac" />
</figure>

Compressed tracks:

| VBR Bitrate | Opus | AAC | Ogg | MP3 |
| ----------- | ---- | --- | --- | --- |
| ~256k | <figure><figcaption>opusenc, vbr256, 274k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-opus-vbr256k-274k.opus" /></figure> | <figure><figcaption>qaac, q109, 236k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-1-qaac-q109-236k.m4a" /></figure> | <figure><figcaption>oggenc2, q8, 239k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-vorbis-q8-239k.ogg" /></figure> | <figure><figcaption>lame, v0, 256k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-1-lame-v0-256k.mp3" /></figure> | 
| ~192k | <figure><figcaption>opusenc, vbr192, 210k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-opus-vbr192k-210k.opus" /></figure> | <figure><figcaption>qaac, q91, 180k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-1-qaac-q91-180k.m4a" /></figure> | <figure><figcaption>oggenc2, q6, 183k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-vorbis-q6-183k.ogg" /></figure> | <figure><figcaption>lame, v2, 183k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-1-lame-v2-183k.mp3" /></figure> | 
| ~160k | <figure><figcaption>opusenc, vbr160, 179k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-opus-vbr160k-179k.opus" /></figure> | <figure><figcaption>qaac, q82, 149k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-1-qaac-q82-149k.m4a" /></figure> | <figure><figcaption>oggenc2, q5, 158k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-vorbis-q5-158k.ogg" /></figure> | <figure><figcaption>lame, v4, 147k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-1-lame-v4-147k.mp3" /></figure> | 
| ~128k | <figure><figcaption>opusenc, vbr128, 144k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-opus-vbr128k-144k.opus" /></figure> | <figure><figcaption>qaac, q64, 119k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-1-qaac-q64-119k.m4a" /></figure> | <figure><figcaption>oggenc2, q4, 134k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-vorbis-q4-134k.ogg" /></figure> | <figure><figcaption>lame, v5, 126k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-1-lame-v5-126k.mp3" /></figure> | 
| ~96k | <figure><figcaption>opusenc, vbr96, 109k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-opus-vbr96k-109k.opus" /></figure> | <figure><figcaption>qaac, q45, 90k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-1-qaac-q45-90k.m4a" /></figure> | <figure><figcaption>oggenc2, q2, 95k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-vorbis-q2-95k.ogg" /></figure> | <figure><figcaption>lame, v7, 100k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-1-lame-v7-100k.mp3" /></figure> | 
| ~64k | <figure><figcaption>opusenc, vbr64, 75k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-opus-vbr64k-75k.opus" /></figure> | <figure><figcaption>qaac, q27, 66k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-1-qaac-q27-66k.m4a" /></figure> | <figure><figcaption>oggenc2, q0, 62k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-1-vorbis-q0-62k.ogg" /></figure> | <figure><figcaption>lame, v9, 70k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-1-lame-v9-70k.mp3" /></figure> | 

##### Vocal with more complex instruments

Reference track:

<figure>
<figcaption>flac, best, 1089k</figcaption>
<audio 
style="margin:0 24px 0 24px;" 
controls loop preload="none" 
type="audio/flac" 
src="media/orange-2-flac-1089k.flac" />
</figure>

Compressed tracks:

| VBR Bitrate | Opus | AAC | Ogg | MP3 |
| ----------- | ---- | --- | --- | --- |
| ~256k | <figure><figcaption>opusenc, vbr256, 262k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-opus-vbr256k-262k.opus" /></figure> | <figure><figcaption>qaac, q109, 270k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-2-qaac-q109-270k.m4a" /></figure> | <figure><figcaption>oggenc2, q8, 266k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-vorbis-q8-266k.ogg" /></figure> | <figure><figcaption>lame, v0, 288k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-2-lame-v0-288k.mp3" /></figure> | 
| ~192k | <figure><figcaption>opusenc, vbr192, 200k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-opus-vbr192k-200k.opus" /></figure> | <figure><figcaption>qaac, q91, 200k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-2-qaac-q91-200k.m4a" /></figure> | <figure><figcaption>oggenc2, q6, 201k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-vorbis-q6-201k.ogg" /></figure> | <figure><figcaption>lame, v2, 206k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-2-lame-v2-206k.mp3" /></figure> | 
| ~160k | <figure><figcaption>opusenc, vbr160, 169k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-opus-vbr160k-169k.opus" /></figure> | <figure><figcaption>qaac, q82, 165k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-2-qaac-q82-165k.m4a" /></figure> | <figure><figcaption>oggenc2, q5, 170k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-vorbis-q5-170k.ogg" /></figure> | <figure><figcaption>lame, v4, 154k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-2-lame-v4-154k.mp3" /></figure> | 
| ~128k | <figure><figcaption>opusenc, vbr128, 136k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-opus-vbr128k-136k.opus" /></figure> | <figure><figcaption>qaac, q64, 129k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-2-qaac-q64-129k.m4a" /></figure> | <figure><figcaption>oggenc2, q4, 142k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-vorbis-q4-142k.ogg" /></figure> | <figure><figcaption>lame, v5, 134k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-2-lame-v5-134k.mp3" /></figure> | 
| ~96k | <figure><figcaption>opusenc, vbr96, 102k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-opus-vbr96k-102k.opus" /></figure> | <figure><figcaption>qaac, q45, 96k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-2-qaac-q45-96k.m4a" /></figure> | <figure><figcaption>oggenc2, q2, 97k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-vorbis-q2-97k.ogg" /></figure> | <figure><figcaption>lame, v7, 101k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-2-lame-v7-101k.mp3" /></figure> | 
| ~64k | <figure><figcaption>opusenc, vbr64, 69k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-opus-vbr64k-69k.opus" /></figure> | <figure><figcaption>qaac, q27, 69k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/orange-2-qaac-q27-69k.m4a" /></figure> | <figure><figcaption>oggenc2, q0, 62k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/orange-2-vorbis-q0-62k.ogg" /></figure> | <figure><figcaption>lame, v9, 68k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/orange-2-lame-v9-68k.mp3" /></figure> | 

#### Vision

The second song will be a more complex, or demanding one --- *Vision* by 中島岬:

*Vision* reference track:

<figure>
<figcaption>flac, best, 1058k</figcaption>
<audio 
style="margin:0 24px 0 24px;" 
controls loop preload="none" 
type="audio/flac" 
src="media/vision-flac-1058k.flac" />
</figure>

*Vision* compressed tracks:

| VBR Bitrate | Opus | AAC | Ogg | MP3 |
| ----------- | ---- | --- | --- | --- |
| ~256k | <figure><figcaption>opusenc, vbr256, 260k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-opus-vbr256k-260k.opus" /></figure> | <figure><figcaption>qaac, q109, 297k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/vision-qaac-q109-297k.m4a" /></figure> | <figure><figcaption>oggenc2, q8, 290k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-vorbis-q8-290k.ogg" /></figure> | <figure><figcaption>lame, v0, 288k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/vision-lame-v0-288k.mp3" /></figure> | 
| ~192k | <figure><figcaption>opusenc, vbr192, 197k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-opus-vbr192k-197k.opus" /></figure> | <figure><figcaption>qaac, q91, 218k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/vision-qaac-q91-218k.m4a" /></figure> | <figure><figcaption>oggenc2, q6, 212k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-vorbis-q6-212k.ogg" /></figure> | <figure><figcaption>lame, v2, 209k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/vision-lame-v2-209k.mp3" /></figure> | 
| ~160k | <figure><figcaption>opusenc, vbr160, 165k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-opus-vbr160k-165k.opus" /></figure> | <figure><figcaption>qaac, q82, 178k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/vision-qaac-q82-178k.m4a" /></figure> | <figure><figcaption>oggenc2, q5, 175k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-vorbis-q5-175k.ogg" /></figure> | <figure><figcaption>lame, v4, 156k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/vision-lame-v4-156k.mp3" /></figure> | 
| ~128k | <figure><figcaption>opusenc, vbr128, 133k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-opus-vbr128k-133k.opus" /></figure> | <figure><figcaption>qaac, q64, 142k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/vision-qaac-q64-142k.m4a" /></figure> | <figure><figcaption>oggenc2, q4, 139k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-vorbis-q4-139k.ogg" /></figure> | <figure><figcaption>lame, v5, 135k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/vision-lame-v5-135k.mp3" /></figure> | 
| ~96k | <figure><figcaption>opusenc, vbr96, 100k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-opus-vbr96k-100k.opus" /></figure> | <figure><figcaption>qaac, q45, 109k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/vision-qaac-q45-109k.m4a" /></figure> | <figure><figcaption>oggenc2, q2, 99k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-vorbis-q2-99k.ogg" /></figure> | <figure><figcaption>lame, v7, 109k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/vision-lame-v7-109k.mp3" /></figure> | 
| ~64k | <figure><figcaption>opusenc, vbr64, 66k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-opus-vbr64k-66k.opus" /></figure> | <figure><figcaption>qaac, q27, 77k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mp4" src="media/vision-qaac-q27-77k.m4a" /></figure> | <figure><figcaption>oggenc2, q0, 63k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/ogg" src="media/vision-vorbis-q0-63k.ogg" /></figure> | <figure><figcaption>lame, v9, 73k</figcaption><audio style="margin:0 24px 0 24px;" controls loop preload="none" type="audio/mpeg" src="media/vision-lame-v9-73k.mp3" /></figure> | 

> You can clearly see the AAC and MP3 encoders tend to give a higher bitrate than target bitrate in VBR mode to handle complex songs.

> Want to listen to your own song at differnet bitrates? Use [this script](convert.js) to encode it to all formats. This is exactly the same script that I wrote to encode the songs and generate the table above.

Now, you should have your own understanding of the different codecs: above which bitrate of which codec is transparent to you.

### My take on the codecs

Here is my opinion: **since ~192k Opus is already transparent to me (and to most people), why use 1000+ kbps FLAC? I can save a lot of space, without even tell a difference!** Unless you have outstandingly gifted ears with high-end equipments, or you do heavy post-processing on audio, you should and will be fine with a transparent lossy encoding.

Also, most audio in animes is voice, which is usually not complex for encoders, so the actual bitrate can be even lower to sound good.

## Still writing...

The rest is still being written...
