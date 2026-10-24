// Liquid Glass lens for a rounded-rect (capsule) surface, used as a backdrop
// filter: the (already blurred) backdrop is refracted near the rim, the way
// a thick convex lens bends what is behind it, and its saturation boosted.
//
// After Kyant's `lens` effect (io.github.kyant0:backdrop, used by
// SimpMusic): inside a band of uHeight px along the edge, each pixel samples
// the backdrop displaced inwards along the shape's normal by a circular
// profile, amount * (1 - sqrt(1 - x^2)), strongest at the rim. Everything
// is in physical pixels of the render target.

#version 460 core

#include <flutter/runtime_effect.glsl>

// Set by the engine: size of the backdrop texture.
uniform vec2 uSize;
// The surface: left, top, width, height.
uniform vec4 uRect;
uniform float uRadius;
// Width of the refracting band along the rim.
uniform float uHeight;
// Displacement at the very rim.
uniform float uAmount;
uniform float uSaturation;

uniform sampler2D uTexture;

out vec4 fragColor;

// No y flip for OpenGL ES here: verified on Windows (Impeller over ANGLE),
// where a backdrop texture arrives the right way up.
vec4 backdropAt(vec2 p) {
  return texture(uTexture, clamp(p / uSize, vec2(0.0), vec2(1.0)));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 halfSize = uRect.zw * 0.5;
  vec2 p = frag - (uRect.xy + halfSize);
  float r = min(uRadius, min(halfSize.x, halfSize.y));

  // Signed distance to the rounded rect (negative inside).
  vec2 q = abs(p) - halfSize + vec2(r);
  float sd = min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
  float depth = -sd;

  vec2 pos = frag;
  if (uHeight > 0.0 && depth < uHeight) {
    // Outward normal: radial in the corners, axis-aligned on the flats.
    vec2 n;
    if (q.x > 0.0 && q.y > 0.0) {
      n = normalize(q);
    } else if (q.x > q.y) {
      n = vec2(1.0, 0.0);
    } else {
      n = vec2(0.0, 1.0);
    }
    n *= sign(p);
    float x = 1.0 - clamp(depth, 0.0, uHeight) / uHeight;
    float d = (1.0 - sqrt(1.0 - x * x)) * uAmount;
    pos = frag - n * d;
  }

  vec4 c = backdropAt(pos);
  float luma = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
  c.rgb = clamp(mix(vec3(luma), c.rgb, uSaturation), vec3(0.0), vec3(c.a));
  fragColor = c;
}
