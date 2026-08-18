// CaptureComposer — the painting half of the capture vocabulary. Where
// CaptureSize answers "how big and where", CaptureComposer does the two
// canvas jobs every capture surface needs and nobody should hand-roll
// twice:
//
//   1. `paintComposite` — the device composite: bezel <img> underneath,
//      live screen canvas on top clipped to the inner corner radius, with
//      an optional overlay (pinch dots) painted inside that clip. This is
//      the logic CaptureGallery and BrowserRecorder each had their own
//      copy of, down to the same hand-rolled rounded-rect path.
//   2. `compose` — place a source-coordinate paint into a target-sized
//      canvas: clear, fill the background, then translate/scale so the
//      callback can keep painting in the source's own coordinates.
//
//   const plan = size.plan(sw, sh, fit);
//   canvas.width = plan.width; canvas.height = plan.height;
//   CaptureComposer.compose(ctx, plan, '#ffffff', (c) => {
//     CaptureComposer.paintComposite(c, { frameImg, screen, sourceCanvas });
//   });
//
// Z-order is not a style choice: DeviceKit composite PDFs paint an opaque
// dark "off glass" inside the screen cutout, authored to sit UNDER live
// content. Bezel first, screen second — the same order the live DOM uses
// (frameImg z-index 1, screenArea z-index 2).
(function (root) {
  'use strict';

  class CaptureComposer {
    /**
     * The composite's natural size — the bezel viewport when a decoded
     * bezel image and a screen layout are both available, the bare source
     * canvas otherwise.
     *
     * @param {{naturalWidth:number}|null} frameImg
     * @param {object|null} screen  SDK SimulatorDefinition.screen
     * @param {{width:number,height:number}|null} sourceCanvas
     */
    static compositeSize(frameImg, screen, sourceCanvas) {
      if (frameImg && frameImg.naturalWidth > 0 && screen && screen.viewport) {
        return {
          width: screen.viewport.width,
          height: screen.viewport.height,
        };
      }
      if (sourceCanvas && sourceCanvas.width > 0) {
        return { width: sourceCanvas.width, height: sourceCanvas.height };
      }
      return { width: 0, height: 0 };
    }

    /**
     * Paint the device composite at its natural size, origin (0, 0).
     *
     * @param {CanvasRenderingContext2D} ctx
     * @param {object} opts
     * @param {HTMLImageElement|null} opts.frameImg
     * @param {object|null} opts.screen        SDK SimulatorDefinition.screen
     * @param {HTMLCanvasElement} opts.sourceCanvas
     * @param {(ctx, rect) => void} [opts.onOverlay] painted inside the clip
     */
    static paintComposite(ctx, { frameImg, screen, sourceCanvas, onOverlay }) {
      const useBezel = frameImg && frameImg.naturalWidth > 0
        && screen && screen.viewport && screen.rect;
      // Capturing before the first frame decodes is ordinary — the
      // stream may still be negotiating. The bezel is already loaded, so
      // an undecoded source costs you the screen layer, not the whole
      // composite; without this, a Record pressed a beat too early
      // produced entirely empty frames.
      const hasContent = !!sourceCanvas && sourceCanvas.width > 0;
      if (!useBezel && !hasContent) return;

      if (!useBezel) {
        const rect = {
          x: 0, y: 0, width: sourceCanvas.width, height: sourceCanvas.height,
        };
        ctx.drawImage(sourceCanvas, rect.x, rect.y, rect.width, rect.height);
        if (onOverlay) onOverlay(ctx, rect);
        return;
      }

      const vp = screen.viewport;
      const rect = screen.rect;
      ctx.drawImage(frameImg, 0, 0, vp.width, vp.height);
      if (!hasContent) return;
      ctx.save();
      CaptureComposer.roundRectPath(
        ctx, rect.x, rect.y, rect.width, rect.height, screen.clipRadius || 0
      );
      ctx.clip();
      ctx.drawImage(sourceCanvas, rect.x, rect.y, rect.width, rect.height);
      if (onOverlay) onOverlay(ctx, rect);
      ctx.restore();
    }

    /**
     * Clear + background-fill the target canvas, then run `paint` with the
     * transform set so it can draw in SOURCE coordinates. `plan` comes
     * from `CaptureSize.plan(sourceW, sourceH, fit)`.
     *
     * @param {CanvasRenderingContext2D} ctx
     * @param {object} plan   { width, height, drawX, drawY, drawW, drawH }
     * @param {string} background  'transparent' or a CSS colour
     * @param {(ctx) => void} paint
     */
    static compose(ctx, plan, background, paint) {
      ctx.clearRect(0, 0, plan.width, plan.height);
      if (background && background !== 'transparent') {
        ctx.fillStyle = background;
        ctx.fillRect(0, 0, plan.width, plan.height);
      }
      if (!(plan.drawW > 0) || !(plan.drawH > 0)) return;

      // The plan's draw rect is the *source* box mapped into the target;
      // dividing by the source box recovers the scale the callback's own
      // coordinates need.
      const sourceW = plan.sourceWidth || plan.drawW;
      const sourceH = plan.sourceHeight || plan.drawH;
      if (!(sourceW > 0) || !(sourceH > 0)) return;
      ctx.save();
      ctx.translate(plan.drawX, plan.drawY);
      ctx.scale(plan.drawW / sourceW, plan.drawH / sourceH);
      paint(ctx);
      ctx.restore();
    }

    /** The bezel's inner rounded rect — the screen's own corner radius. */
    static roundRectPath(ctx, x, y, w, h, r) {
      ctx.beginPath();
      ctx.moveTo(x + r, y);
      ctx.lineTo(x + w - r, y);
      ctx.quadraticCurveTo(x + w, y, x + w, y + r);
      ctx.lineTo(x + w, y + h - r);
      ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
      ctx.lineTo(x + r, y + h);
      ctx.quadraticCurveTo(x, y + h, x, y + h - r);
      ctx.lineTo(x, y + r);
      ctx.quadraticCurveTo(x, y, x + r, y);
      ctx.closePath();
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._CaptureComposer = CaptureComposer;
})(window);
