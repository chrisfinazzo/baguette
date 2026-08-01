// ScreenQuad — pure perspective-quad math for mapping a 2D click onto a
// screen mesh rendered at an arbitrary camera pose (baguette's live 3D
// stream). No DOM/canvas ownership beyond `getBoundingClientRect` for the
// content-rect helper; everything else is plain vector math, independent
// of PointerInterpreter/Sim3DPanel so either can consume it without the
// other.
(function (root) {
  'use strict';

  /** Server wire shape `[[x,y],[x,y],[x,y],[x,y]]` (TL,TR,BR,BL) → quad. */
  function fromCorners(corners) {
    if (!Array.isArray(corners) || corners.length !== 4) return null;
    const [topLeft, topRight, bottomRight, bottomLeft] = corners;
    return {
      topLeft: { u: topLeft[0], v: topLeft[1] },
      topRight: { u: topRight[0], v: topRight[1] },
      bottomRight: { u: bottomRight[0], v: bottomRight[1] },
      bottomLeft: { u: bottomLeft[0], v: bottomLeft[1] },
    };
  }

  // The canvas's CSS box may be larger than its drawn content when
  // `object-fit: contain` letterboxes the backing store inside it — this
  // finds the actual drawn (content) rect so client coordinates line up
  // with quad corners normalized to the rendered frame.
  function contentRect(canvas) {
    const box = canvas.getBoundingClientRect();
    const contentAspect = canvas.width / canvas.height;
    const boxAspect = box.width / box.height;
    let width, height;
    if (contentAspect > boxAspect) {
      width = box.width;
      height = box.width / contentAspect;
    } else {
      height = box.height;
      width = box.height * contentAspect;
    }
    return {
      left: box.left + (box.width - width) / 2,
      top: box.top + (box.height - height) / 2,
      width,
      height,
    };
  }

  function crossXY(a, b) {
    return a.x * b.y - a.y * b.x;
  }

  // Solves for (u,v) in [0,1]×[0,1] such that bilinear interpolation of
  // the quad's four corners at (u,v) lands on (px,py) — the inverse of
  // the forward map used to place the corners. `inside` is false when
  // (px,py) falls outside the quad (bezel/body/background around the
  // rendered screen).
  function inverseBilinear(quad, px, py) {
    const a0 = quad.topLeft, b0 = quad.topRight;
    const c0 = quad.bottomRight, d0 = quad.bottomLeft;
    const e = { x: b0.u - a0.u, y: b0.v - a0.v };
    const f = { x: d0.u - a0.u, y: d0.v - a0.v };
    const g = { x: a0.u - b0.u - d0.u + c0.u, y: a0.v - b0.v - d0.v + c0.v };
    const h = { x: px - a0.u, y: py - a0.v };

    const qa = crossXY(g, f);
    const qb = crossXY(e, f) + crossXY(h, g);
    const qc = crossXY(h, e);

    let v;
    if (Math.abs(qa) < 1e-9) {
      v = Math.abs(qb) < 1e-9 ? 0 : -qc / qb;
    } else {
      const discriminant = qb * qb - 4 * qa * qc;
      if (discriminant < 0) return { u: 0.5, v: 0.5, inside: false };
      const sqrtDiscriminant = Math.sqrt(discriminant);
      const v1 = (-qb + sqrtDiscriminant) / (2 * qa);
      const v2 = (-qb - sqrtDiscriminant) / (2 * qa);
      const inRange = (value) => value >= -0.001 && value <= 1.001;
      if (inRange(v1) && !inRange(v2)) v = v1;
      else if (inRange(v2) && !inRange(v1)) v = v2;
      else v = Math.abs(v1 - 0.5) <= Math.abs(v2 - 0.5) ? v1 : v2;
    }

    const denomX = e.x + v * g.x;
    const denomY = e.y + v * g.y;
    const u = Math.abs(denomX) >= Math.abs(denomY)
      ? (h.x - v * f.x) / denomX
      : (h.y - v * f.y) / denomY;

    // A small epsilon so a click landing right at the visual edge —
    // exactly what edge-band gestures target — doesn't get rejected by
    // floating-point noise from the quadratic solve.
    const epsilon = 0.001;
    const inside = u >= -epsilon && u <= 1 + epsilon && v >= -epsilon && v <= 1 + epsilon;
    return { u, v, inside };
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._ScreenQuad = { fromCorners, contentRect, inverseBilinear };
})(window);
