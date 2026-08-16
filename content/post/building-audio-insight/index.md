---
title: "Building Audio Insight: An Audio Analyzer That Actually Renders Smoothly"
description: Why I built an open-source audio analysis plugin, how its analyzers work, and what it took to make its Metal interface run smoothly.
slug: building-audio-insight
date: 2026-08-16 16:42:45+0800
categories:
    - Audio
    - macOS
    - Development
tags:
    - Audio Insight
    - Audio Unit
    - VST3
    - Metal
    - DSP
    - Performance
---

I like audio analyzers. It answers questions that my ears alone cannot answer quickly. Where is that resonance? Is the low end actually mono? How loud is this over the whole track? Is a limiter catching an occasional peak, or working all the time?

What I do not like is an analyzer whose interface feels slower than the display it runs on.

On my M1 Max, Excite Audio VISION 4X appeared to top out at roughly 30 FPS, with inconsistent frame timing, while consuming about one CPU core. iZotope Insight 2 looked smoother, but in my experience it was comparatively resource-heavy and expensive. These were observations from my own setup, not controlled benchmarks that apply to every machine, host, and plugin version. Still, they were enough to make me wonder: how difficult would it be to build the analyzer I wanted?

That became [Audio Insight](https://github.com/charlie0129/audio-insight), an open-source AUv2 and VST3 analyzer for macOS. Its first goal is deliberately narrow: show useful measurements, leave the audio unchanged, keep real-time callback work bounded, and make the interface feel native on a high-refresh-rate display.

![Audio Insight dashboard with all five analyzers](images/audio-insight-dashboard.png)

The project is still early, but it already has a Spectrum, Spectrogram, Peak/RMS meter, stereo vectorscope and correlation meter, and BS.1770 loudness measurements. Four grid-snapped splitters resize the dashboard tiles, the analysis parameters are adjustable, and a built-in metrics panel makes the renderer's behavior visible instead of leaving performance to intuition.

This post is about how it works, but mostly about the unexpectedly interesting work required to make a meter move smoothly.

## What an audio plugin actually does

People who use plugins often picture them as little applications inside a DAW. That is a useful mental model for the interface, but not for the audio path.

An AU or VST3 plugin is code loaded by a host (or, in some hosts, a separate hosting service). The host repeatedly gives the plugin a small block of samples by calling its processing function. At 48 kHz with 512-sample blocks, a new block arrives about every 10.7 milliseconds. The plugin has to finish before the hardware needs the result. Missing that deadline can produce a click or dropout.

Audio Insight is a transparent effect: it observes supported mono or stereo audio and leaves the samples unchanged. Even so, its callback has to follow the same real-time rules as a compressor or synthesizer. It cannot allocate memory, take a lock, wait for another thread, write a log, open a file, call the UI, or ask the GPU to draw something. Any of those operations can take an unpredictable amount of time.

The resulting design looks like this:

```text
host audio callback
        ↓
bounded, non-blocking capture
        ↓
per-instance analysis coordinator
        ↓
shared two-worker analysis pool
        ↓
immutable measurement snapshots
        ↓
display-linked Metal renderer
```

The callback only captures bounded chunks into preallocated storage and updates the few measurements that must inspect every sample. A per-instance coordinator coalesces work, and all instances loaded in the same plugin module share two analysis workers. There is at most one running or queued job per instance, so opening many plugin windows does not create a thread for every visualization.

The workers publish immutable snapshots. The UI reads the newest complete snapshot whenever it draws; it never waits for analysis to finish. This separation matters. Analysis targets 60 slices per second, but the latest-wins scheduler can skip stale work rather than build a backlog. Meanwhile, a ProMotion display can render at around 120 Hz. The renderer can advance display motion between discrete analysis updates without running twice as many FFTs.

All five visualizations share one Metal canvas, drawable, command buffer, and render pass. JUCE supplies the plugin shell and cross-format plumbing, while the visual layer is native Metal. Coordinates and layout use logical points, and drawable and text resources follow the current backing scale. The implementation is therefore designed to support both regular-density and Retina displays, including live backing-scale changes.

When the editor is closed, there is nothing to display, so capture, analysis, history, display-link callbacks, and Metal submissions stop. Audio still passes through normally. Reopening the editor begins fresh rather than silently spending host resources on invisible history.

## Turning samples into pictures

The analyzers share infrastructure, but each one answers a different question. Here is the calculation path in a little more detail.

### Spectrum: what frequencies exist now?

![Audio Insight Spectrum](images/audio-insight-spectrum.png)

The Spectrum takes a short window of recent audio and uses a fast Fourier transform (FFT) to divide it into frequency bins. By default the transform size is \(N=8192\) samples, or about 171 milliseconds at a sample rate \(F_s=48\) kHz. This does **not** delay the audio by 171 ms; the plugin passes audio through immediately. It means the displayed estimate describes roughly that much recent history.

The FFT bin centers are separated by \(\Delta f=F_s/N\). With the defaults, that is approximately 5.86 Hz. This number is useful, but it is not the same as saying two tones 5.86 Hz apart can always be resolved: the selected window also determines how widely a tone spreads into nearby bins.

Before the FFT, samples are multiplied by a periodic five-term flat-top window \(w[n]\). Cutting an arbitrary piece from a continuous waveform creates artificial edges, which spread energy across the spectrum. A window tapers the data to control that leakage. A flat-top window trades some ability to separate nearby tones for better amplitude accuracy, which is a useful default for a measurement tool.

For channel \(c\), the transform is:

\[
\begin{aligned}
X_c[k]&=\sum_{n=0}^{N-1}x_c[n]\,w[n]e^{-j2\pi kn/N},\\
f_k&=\frac{kF_s}{N}.
\end{aligned}
\]

Audio Insight corrects the window's coherent gain—the amplitude scaling introduced by multiplying by \(w[n]\)—with \(W=\sum_n w[n]\). Real-valued audio has mirrored positive- and negative-frequency FFT bins, but the graph needs only the nonnegative half. In this one-sided view, the DC bin at 0 Hz and the Nyquist bin at \(F_s/2\) use \(1/W\); every bin between them represents both mirrored sides and uses \(2/W\). The calibrated stereo power and level are therefore:

\[
\begin{aligned}
a_k&=
\begin{cases}
1/W, & k=0\ \text{or}\ k=N/2,\\
2/W, & \text{otherwise},
\end{cases}\\[3pt]
P[k]&=\max_c\left(a_k|X_c[k]|\right)^2,\\
D[k]&=10\log_{10}P[k].
\end{aligned}
\]

For mono, the maximum contains only one channel. For stereo, taking the larger channel magnitude avoids first mixing the waveforms to mono, where out-of-phase content could cancel. The calibration makes a bin-centered full-scale sine read 0 dB internally; powers at or below \(10^{-18}\) are displayed at the \(-180\) dB analysis floor.

Attack and Release then smooth each bin in **linear power**, not in dB. Given the elapsed time \(\Delta t\) and the selected time constant \(\tau_d\):

\[
\begin{aligned}
\alpha_d&=
\begin{cases}
0, & d\text{ is Off},\\
e^{-\Delta t/\tau_d}, & d\text{ is enabled},
\end{cases}\\[3pt]
\bar P_t[k]&=\alpha_d\bar P_{t-1}[k]+(1-\alpha_d)P_t[k].
\end{aligned}
\]

The direction \(d\) is Attack when \(P_t[k]\geq\bar P_{t-1}[k]\), otherwise Release. An Off direction follows the current FFT immediately. The default Attack is Off, allowing a short burst to appear at once, while the default 250 ms Release lets the trace fall more slowly. Peak hold, when enabled, operates on unsmoothed power instead of \(\bar P\).

Transforms target a slice rate \(R_s\) using a hop of \(H=\max(1,\operatorname{round}(F_s/R_s))\) new samples. At 48 kHz and 60 slices per second, \(H=800\), so adjacent 8,192-sample windows overlap by about 90.2%. The first result still waits for one complete window, and the latest-wins scheduler may skip stale transforms under load instead of building a backlog.

![Spectrum Attack and Release controls](images/audio-insight-spectrum-settings.png)

Spectrum and Spectrogram use the same continuously adjustable frequency scale. For a frequency \(f\) between \(f_0\) and \(f_1\), the scale control \(s\) blends normalized linear and logarithmic coordinates:

\[
\begin{aligned}
u_{\mathrm{lin}}(f)&=\frac{f-f_0}{f_1-f_0},\\
u_{\log}(f)&=\frac{\ln(f/f_0)}{\ln(f_1/f_0)},\\
u(f,s)&=(1-s)u_{\mathrm{lin}}(f)+s\,u_{\log}(f).
\end{aligned}
\]

Here \(f_0=20\) Hz and \(f_1=\min(20\text{ kHz},F_s/2)\). The default is \(s=0.8\). At \(s=0\), equal distances represent equal numbers of hertz. At \(s=1\), equal ratios such as 100→200 Hz and 1→2 kHz occupy equal distances. Values in between preserve more low-frequency detail without compressing the entire treble into a tiny area. Spectrum uses \(x=u\), while Spectrogram uses \(y=1-u\) so high frequencies appear at the top. Axis labels are chosen dynamically: important anchors win first, then extra candidates fill only the space that remains.

### Spectrogram: how did the spectrum change?

![Audio Insight Spectrogram](images/audio-insight-spectrogram.png)

A Spectrum is one slice through time. A Spectrogram keeps those slices and scrolls them sideways, using color for level. Transients become vertical marks, steady tones become horizontal lines, and harmonics become stacks of related lines.

Each Spectrogram column starts from the same raw power \(P[k]\) as Spectrum, before Spectrum's Attack/Release averaging. Let \(\mathcal K\) contain only usable bin centers from 20 Hz through \(f_1\), and let \(R_f=\min(1024,|\mathcal K|)\) be the texture's frequency-row count. For a usable bin at \(f_k=kF_s/N\), define \(q_k=u(f_k,s)\). Its row is:

\[
r(k)=\min\left(R_f-1,\left\lfloor R_f q_k\right\rfloor\right).
\]

For a row containing one or more bin centers, \(P_r\) is the greatest \(P[k]\) assigned to that row. Taking the maximum, rather than the average, helps a narrow tonal trace survive when several FFT bins land in one display row. If a row contains no bin center—common at low frequencies with a small FFT—the mapper inverse-maps the row center and linearly interpolates the two surrounding bins in power. It is honest interpolation between available samples, not a claim of extra frequency resolution.

Power at or below \(10^{-18}\) becomes \(-180\) dB; otherwise the mapper stores \(D_r=10\log_{10}P_r\). These values go into a circular Metal texture with one 16-bit floating-point level per cell (R16Float). The texture stores calibrated dB rather than finished colors. In the shader, let \(F\) be the selected floor, \(C\) the ceiling, and \(\eta\) the Color response:

\[
\begin{aligned}
v&=\operatorname{clamp}\left(
\frac{D_r-F}{C-F},0,1\right),\\
\gamma&=2^\eta,\\
c_{\mathrm{palette}}&=v^\gamma.
\end{aligned}
\]

The value \(c_{\mathrm{palette}}\) selects a point in the chosen palette. Response 0 is linear in dB; negative values reveal quieter detail, while positive values suppress low energy and emphasize stronger traces. Because this work happens in the shader, changing palette, range, or response recolors existing history without rerunning the FFT.

For a history duration \(T\) and requested slice rate \(R_s\), the texture uses \(\min(8192,\lceil TR_s\rceil)\) columns. The default ten seconds at 60 slices per second therefore needs 600 columns. A write index wraps around the texture, and the renderer changes texture coordinates instead of copying the whole image to scroll it. Missing timestamp intervals become black columns rather than stretching old information across time.

### Peak and RMS: how strong is the signal?

![Audio Insight Peak/RMS meter](images/audio-insight-peak-rms.png)

Peak and RMS intentionally describe different things.

Sample peak examines every sample. Its live value has instantaneous attack and a 20 dB/s release:

\[
\begin{aligned}
\lambda_p&=10^{-20/(20F_s)},\\
p[n]&=\max\left(|x[n]|,\lambda_p p[n-1]\right).
\end{aligned}
\]

In other words, a new larger sample wins immediately; otherwise the old indication decays by the amount corresponding to one sample period. A separate hold marker keeps a new maximum for two seconds, then falls at the same 20 dB/s rate. The OVER indicator latches when \(|x[n]|\geq1\), although the label deliberately does not claim that floating-point audio at 0 dBFS proves waveform clipping.

RMS estimates sustained signal power. With the 300 ms time constant \(\tau=0.300\) s, Audio Insight updates an exponential mean square for every sample:

\[
\begin{aligned}
\alpha&=e^{-1/(F_s\tau)},\\
q[n]&=\alpha q[n-1]+(1-\alpha)x[n]^2,\\
\operatorname{RMS}[n]&=\sqrt{q[n]},\\
D_{\mathrm{RMS}}[n]&=20\log_{10}\operatorname{RMS}[n].
\end{aligned}
\]

This is an exponential response, not a rectangular box containing exactly the latest 300 ms. It also has no AES17 \(+3.01\) dB calibration offset, so a full-scale sine reads approximately \(-3.01\) dBFS RMS. Peak reveals brief extremes; RMS behaves more like a view of sustained energy. The peak remains a **sample peak**, not an oversampled true-peak/dBTP measurement, so it does not predict a possibly larger value between stored samples.

These ballistics run on the bounded real-time capture path and inspect every sample. Their meaning therefore does not change if an analysis worker is briefly late.

### Stereo: how are left and right related?

![Audio Insight Vectorscope and Correlation meter](images/audio-insight-stereo-correlation.png)

The vectorscope turns each stereo sample pair into a point:

\[
x_{\mathrm{scope}}=\frac{R-L}{2},
\qquad
y_{\mathrm{scope}}=\frac{L+R}{2}.
\]

Audio shared equally by both channels has \(x=0\) and lies on the vertical center axis. Opposite-phase audio has \(y=0\) and spreads horizontally. The coordinates remain tied to full scale rather than being normalized independently on every frame, so a quiet signal is not made to look artificially loud.

The field keeps the latest 250 ms but bounds its GPU data. For \(W_f=\lceil0.25F_s\rceil\) captured frames, the worker selects one pair every:

\[
d=\left\lceil\frac{W_f}{4096}\right\rceil
\]

frames. At 48 kHz, \(W_f=12000\), \(d=3\), and the cloud contains about 4,000 uniformly spaced points. Their opacity fades with age. This decimation changes only the picture; it does not change the correlation measurement.

The adjacent correlation value uses every sample, with 300 ms exponentially weighted averages:

\[
\begin{aligned}
\alpha&=e^{-1/(F_s\cdot0.300)},\\
E_n[z]&=\alpha E_{n-1}[z]+(1-\alpha)z[n].
\end{aligned}
\]

\[
\rho[n]=\frac{E_n[LR]}{\sqrt{E_n[L^2]E_n[R^2]}}.
\]

The three running values \(E[L^2]\), \(E[R^2]\), and \(E[LR]\) advance in source-sample order on the real-time side, and the implementation clamps the final ratio to \([-1,1]\) against numerical error. A value near \(+1\) means the channels are strongly alike, \(0\) means little linear relationship, and a negative value warns that mono playback may cancel important content. If either averaged channel power is below \(10^{-9}\), equivalent to \(-90\) dBFS RMS, correlation is reported as unavailable rather than dividing by a nearly zero value. A genuinely mono input is labeled MONO and likewise does not receive a synthetic \(+1\) correlation.

### Loudness: how loud does it feel over time?

![Audio Insight Loudness meters](images/audio-insight-loudness.png)

Raw peak level is not perceived loudness. Audio Insight implements BS.1770-5 K-weighting with the Momentary, Short-term, and Integrated semantics commonly used with EBU R128. K-weighting is a pair of filters: a high-frequency shelf models the head's acoustic effect, and a high-pass stage reduces the contribution of very low frequencies. The code derives their coefficients for the current sample rate.

If \(y_c[n]\) is the K-weighted output of channel \(c\), Audio Insight forms the per-sample energy and a window mean:

\[
\begin{aligned}
e[n]&=\sum_c y_c[n]^2,\\
z_W&=\frac{1}{N_W}\sum_{n\in W}e[n].
\end{aligned}
\]

For the supported mono and stereo layouts, every actual channel has unit weight. Mono therefore contributes once; it is never duplicated into synthetic left and right channels. Surround layouts and their channel weights are outside the current scope. Window energy becomes LUFS (Loudness Units relative to Full Scale) using the BS.1770 offset:

\[
L_W=-0.691+10\log_{10}z_W.
\]

- Momentary loudness covers 400 ms.
- Short-term loudness covers 3 seconds.
- Integrated loudness uses 400 ms blocks completed every 100 ms—75% overlap—from the latest Reset within the current uninterrupted, visible analysis interval.

Momentary and Short-term are simple ungated window measurements. Integrated loudness applies gates: thresholds that exclude blocks from the long-term average. For each 400 ms block \(i\), let its mean-square energy be \(z_i\) and its loudness be \(L_i=-0.691+10\log_{10}z_i\). The absolute-passing set is:

\[
\begin{aligned}
\mathcal A&=\{i\mid L_i>-70\ \mathrm{LUFS}\},\\
\mu_{\mathcal A}&=\frac{1}{|\mathcal A|}\sum_{i\in\mathcal A}z_i.
\end{aligned}
\]

At each Integrated update, one non-iterative relative threshold is calculated 10 LU below the preliminary absolute-gated mean of the history accumulated so far:

\[
\begin{aligned}
\Gamma_{\mathrm{rel}}&=-0.691+10\log_{10}\mu_{\mathcal A}-10,\\
\mathcal R&=\{i\in\mathcal A\mid L_i>\Gamma_{\mathrm{rel}}\}.
\end{aligned}
\]

Finally:

\[
\begin{aligned}
\bar z_{\mathcal R}&=\frac{1}{|\mathcal R|}\sum_{i\in\mathcal R}z_i,\\
L_I&=-0.691+10\log_{10}\bar z_{\mathcal R}.
\end{aligned}
\]

Both comparisons are strict \(>\), and the relative gate is not iterated repeatedly. This two-stage gate prevents silence and very quiet passages from dragging the program average down indefinitely. The tile's Reset command restarts Integrated loudness while ready Momentary/Short-term values and K-weighting continuity remain intact. Editor reactivation, an audio discontinuity, or a format change resets the complete loudness analyzer.

The empty cases are explicit too. If \(\mathcal A\) contains no blocks, the preliminary mean and relative gate remain unavailable. If \(\mathcal R\) is empty, Integrated loudness remains \(-\infty\). The implementation never divides by an empty set.

The implementation does not claim complete EBU Mode compliance: it does not yet include LRA or true peak, for example. The label describes its M/S/I measurement semantics, not a certification.

There is an interesting performance problem hiding in Integrated loudness. Within one uninterrupted visible measurement, the exact answer can cover 24 hours: up to 864,000 blocks. Rescanning every qualifying block every 100 ms would make the cost grow throughout the measurement.

The implementation uses a preallocated sorted index called a B+ tree. It contains finite block energies above the absolute gate and keeps aggregate counts and sums in its branches; all completed blocks still count toward the 24-hour limit. A new relative-gate boundary can be answered by finding one boundary leaf and combining a bounded number of branch totals. Capacity for the worst case occupies about 7.25 MiB on arm64, and the structure never allocates while processing.

## Smooth is a timing property, not an FPS number

The renderer uses `CAMetalDisplayLink`, which supplies a drawable in step with a display. While visible, Audio Insight requests the active display's exact reported maximum refresh rate, with a 60 Hz fallback. That request is best effort—Core Animation and the compositor still control actual presentation—so measured presentation timestamps are the truth.

This distinction became important repeatedly. A counter can say 120 callbacks per second while the screen still changes only 60 times. An average can say 120 FPS while an occasional doubled interval makes scrolling visibly hitch. Smoothness is about the complete chain from callback to presentation and about the distribution of frame intervals, not just one large number.

![Audio Insight running inside SoundSource](images/audio-insight-soundsource.png)

### The plugin that crashed its host

The first AU build appeared for a moment in SoundSource and then disappeared. The host reported only that its Audio Unit hosting service had crashed.

The detailed log led to an assertion in timed drawable presentation. A normal Metal application may call an API such as timed `present`, but a drawable delivered by `CAMetalDisplayLink` has different presentation ownership. Combining the two caused the hosting process to assert. The correct sequence is to commit the command buffer and call plain `present()` on that drawable, while using the display link's target timestamp only for telemetry and scheduling.

This is one reason plugin development needs testing in real hosts. SoundSource exposed an API misuse that a successful build or unit test had not.

### Why 120 display callbacks produced 60 frames

After the crash was fixed, the display link was firing close to 120 times per second, but only about 60 frames were submitted. The built-in metrics captured the pattern:

| Counter | Before the fix |
| --- | ---: |
| Display-link callbacks | 6,453 |
| Metal submissions | 3,230 |
| GPU-backpressure drops | 3,223 |
| Sampled display-link callback rate | ~111/s |
| Sampled Metal submission rate | ~59.6/s |

The cumulative counters cover the full telemetry epoch; the two rates are a sample from its final roughly 0.25 seconds. Almost exactly every other display-link callback was being rejected by the in-flight buffer pool.

The surprising part was that the GPU was not necessarily too slow. Reusable vertex buffers were retained until the drawable was actually presented. The compositor may hold a drawable for several refresh periods even after GPU execution has completed, so all reusable buffers became occupied and the next callback had nowhere to write.

The fix was to separate two lifetimes. GPU command completion now releases the reusable buffers immediately. A small, independent object survives only to correlate the later presentation timestamp. The renderer no longer holds large working resources hostage to compositor timing.

In a later point-in-time M1 Max capture from another development build, with the Metrics panel visible, the drawable was 2,400×1,496 pixels at 2× backing scale. The run recorded 1,188 display-link callbacks, 1,188 submissions, and zero GPU-backpressure drops. Across the most recent 240 presented intervals, the average was 8.438 ms, or 118.52 Hz; 237 intervals were the normal 8.333 ms and three doubled to 16.667 ms. Telemetry also counted 11 skipped presentations over the run. That capture used the then-selected 16,384-point FFT; today's default is 8,192.

The capture demonstrates that the buffer-lifetime bottleneck and its GPU-backpressure drops were gone. It is evidence of approximately display-rate presentation in that run, not a perfect-pacing claim or a controlled comparison with another plugin.

### Making 60 Hz data scroll on a 120 Hz display

The Spectrogram exposed a second kind of stutter. New analysis columns arrive at 60 Hz. If the image moves forward only when a complete column arrives, it necessarily steps every other frame on a 120 Hz display.

The solution was not to double the FFT workload. The renderer advances a fractional scroll head from the target presentation clock while keeping the actual dB cells discrete. A one-slice cushion absorbs ordinary analysis scheduling jitter. If a texture upload is briefly busy, the renderer postpones that upload while continuing to draw the rest of the dashboard.

The result is much smoother motion from the same 60-slices-per-second target. This also explains why raising thread priority would have been the wrong first response: the main issue was the relationship between two clocks, not a shortage of real-time privileges.

### The random resets that were not random

During longer sessions, all graphs would occasionally reset. The recovery was intentional—when audio history has a real gap, temporal analyzers must not pretend the samples on either side were adjacent—but the handoff overflowed far too easily even while host audio was continuous. Sequence tracking then correctly detected the resulting loss.

The original capture queue had 16 logical slots and consumed one for each host callback. Its time capacity therefore depended on the host's block size. A metrics capture reached all 16 ready slots, discarded 20 queued chunks to make room for newer audio, and recorded three consumer discontinuities followed by three Loudness resets.

The redesigned queue packs audio across callback boundaries into 128 slots of 256 frames, retaining 32,768 frames regardless of host callback size. That is about 683 ms at 48 kHz, 341 ms at 96 kHz, or 171 ms at 192 kHz. The capacity and overflow behavior are covered by implementation tests; longer post-redesign host runs remain part of validation. A sufficiently long stall can still overflow it. When that happens, latest data wins and temporal analyzers reset, because joining unrelated pieces of audio would produce convincing but false measurements.

## Building observability into the plugin

Apple's Metal HUD is useful for applications that enable it before creating their first Metal device. A plugin usually arrives after its host has already done that, so it cannot reliably switch the HUD on from a settings button. I replaced that idea with a built-in performance panel available in Release builds.

![Frame pacing and latency composition in the Metrics panel](images/audio-insight-metrics.png)

![Metric details](images/audio-insight-metrics-details.png)

It reports exact frame pacing over the latest 240 presentation intervals, derived from 241 timestamps; CPU, submit, GPU, and compositor latency composition; display-link scheduling; audio-callback histograms; queue occupancy and discontinuities; analyzer freshness; and raw copyable metrics for offline inspection. The stacked latency bar covers the pipeline from a display-link callback to presentation. It is not a breakdown of an 8.33 ms frame budget: several frames can overlap in flight, so its total can exceed one refresh interval without reducing presentation cadence.

Graphs move at vblank, headline numbers refresh at no more than 10 Hz, and the full text table refreshes at 4 Hz. That keeps the visual feedback immediate without rebuilding lots of text 120 times per second. Instrumentation turned several vague reports—“it looks a bit laggy,” “it seems to reset”—into specific, actionable failures.

## An agent-assisted, human-tested development loop

I used coding agents to implement much of Audio Insight. That did not remove the need for a tight feedback loop; it made the loop more important.

The agents could design the threading model, inspect crash logs, add instrumentation, and reason from raw captures. They could build the plugin, but they could not reliably judge how motion felt inside my particular SoundSource setup. At runnable milestones I installed the AU, watched it on the M1 Max, adjusted settings, and returned observations, screenshots, logs, or copied metrics. Those reports led directly to the presentation-lifetime fix, the fractional Spectrogram scroll, dynamic axis labeling, and the queue redesign.

For visual and real-time software, “the code is correct” and “the product feels right” are different claims. An instrumented implementation plus a person looking at the actual display proved far more useful than guessing at either one in isolation.

## What is open source today

The current code identifies itself as Audio Insight 0.1.0. It targets macOS 15 on arm64 and builds AUv2 and VST3. It uses C++20, CMake, a pinned JUCE submodule for the plugin shell, CPU FFT analysis accelerated by Apple's vDSP on macOS, and a native Metal renderer. Project-owned code is licensed under AGPL-3.0-or-later; JUCE retains its own upstream AGPL terms.

The current release policy is pragmatic for a small open-source project: builds use ad hoc signing, and Developer ID signing and notarization are out of scope. Users can build from source. For a downloaded bundle, the documented flow is to verify the published checksum, extract it, clear quarantine only on the intended bundle, apply an ad hoc signature, and verify that signature.

Older macOS versions, Intel/Universal builds, Windows, and AUv3 are architectural possibilities rather than current support promises. Logic compatibility, broader VST3 host coverage, multi-instance stress testing, and several formal performance gates also remain work in progress.

The source, build instructions, and current limitations are all in the [Audio Insight repository](https://github.com/charlie0129/audio-insight). If you use analyzers but have never looked inside one, I hope the code makes the path from samples to pixels a little less mysterious. And if the Spectrogram glides across a 120 Hz display without drawing attention to the renderer, that is exactly the point.
