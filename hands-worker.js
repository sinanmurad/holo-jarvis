// Holo Jarvis — hand tracking off the main thread so the interface never freezes.
// Classic worker: loads MediaPipe's CommonJS bundle through a tiny exports shim.
self.exports = {};
self.module = { exports: self.exports };
let hl = null;

self.onmessage = async (e) => {
  const m = e.data;
  if (m.type === 'init') {
    try {
      importScripts(m.bundle);
      const { FilesetResolver, HandLandmarker } = self.module.exports;
      const fs = await FilesetResolver.forVisionTasks(m.wasm);
      const opts = (d) => ({
        baseOptions: { modelAssetPath: m.model, delegate: d },
        runningMode: 'VIDEO', numHands: 2,
        minHandDetectionConfidence: 0.3, minHandPresenceConfidence: 0.3, minTrackingConfidence: 0.3
      });
      let err;
      for (const d of m.delegates) {
        try { hl = await HandLandmarker.createFromOptions(fs, opts(d)); postMessage({ type: 'ready', delegate: d }); return; }
        catch (x) { err = x; }
      }
      throw err || new Error('model açılamadı');
    } catch (x) {
      postMessage({ type: 'error', message: String((x && x.message) || x) });
    }
    return;
  }
  if (m.type === 'frame') {
    const t0 = performance.now();
    let res = null;
    try { if (hl) res = hl.detectForVideo(m.bitmap, m.t); } catch (x) { /* skip frame */ }
    try { m.bitmap.close(); } catch (x) {}
    postMessage({ type: 'result', landmarks: res ? res.landmarks : [], ms: performance.now() - t0, t: m.t });
  }
};
