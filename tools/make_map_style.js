// Writes Aero/Resources/Map/layers_light.json and layers_dark.json: the map layers of the web app's Location screen
// (projects/aero/home/.local/bin/aero_web.py, locationStyle) for the phone, with the phone's own palette in place of the web theme's.
//
//   node tools/make_map_style.js PATH/TO/projects/aero/home/.local/share/aero/vendor/map/basemaps.js
//
// basemaps.js is @protomaps/basemaps 5.7.2 (BSD-3-Clause, basemaps-LICENSE.md in the Fingus repository). The source name in the layers is "tiles"
// and the Swift side puts the one source (the person's own server) and the glyph and sprite addresses round them. Nothing here names a host.
// Palette values are Tokens.swift's (Look.Palette, Look.Hue); the mixing is the web page's locationMix. "Picked, not grounded": which token
// stands for which of the web theme's colours (deep, metal, fg, second); the web theme has no phone twin.
const fs = require("fs"), vm = require("vm"), path = require("path");
const src = fs.readFileSync(process.argv[2], "utf8");
const ctx = {}; vm.createContext(ctx); vm.runInContext(src + ";this.basemaps = basemaps;", ctx);
const basemaps = ctx.basemaps;
const mix = (a, b, t) => {
  const x = parseInt(a.slice(1), 16), y = parseInt(b.slice(1), 16);
  const ch = s => Math.round(((x >> s) & 255) * (1 - t) + ((y >> s) & 255) * t);
  return "#" + ((1 << 24) + (ch(16) << 16) + (ch(8) << 8) + ch(0)).toString(16).slice(1);
};
const palettes = {
  light: { accent: "#dfe35a", deep: "#2b2c10", fg: "#21210d", metal: "#eceed8", second: "#9ee0c0" },
  dark:  { accent: "#dfe35a", deep: "#101108", fg: "#eef0d4", metal: "#24260f", second: "#9ee0c0" },
};
for (const [name, p] of Object.entries(palettes)) {
  const night = name === "dark";
  const base = basemaps.namedFlavor(name), f = {};
  for (const [k, v] of Object.entries(base)) f[k] = typeof v === "string" && /^#[0-9a-f]{6}$/i.test(v) ? mix(v, p.accent, .1) : v;
  const ground = night ? mix(p.deep, p.fg, .06) : mix(p.metal, p.deep, .5);
  const road = night ? mix(p.deep, p.fg, .2) : mix(p.deep, "#ffffff", .7);
  Object.assign(f, {
    background: ground, earth: ground,
    water: mix(night ? mix(p.deep, "#3b6f9e", .45) : mix(ground, "#7fb2e0", .6), p.accent, .1),
    park_a: mix(ground, p.second, .14), park_b: mix(ground, p.second, .2),
    wood_a: mix(ground, p.second, .12), wood_b: mix(ground, p.second, .16),
    buildings: mix(ground, p.fg, night ? .14 : .08),
    minor_a: road, minor_b: road, minor_service: road, other: road, link: road, major: road,
    highway: mix(road, p.accent, night ? .3 : .45),
    city_label: p.fg, city_label_halo: ground, subplace_label: mix(p.fg, ground, .3), subplace_label_halo: ground,
    roads_label_minor: mix(p.fg, ground, .35), roads_label_minor_halo: ground,
    roads_label_major: mix(p.fg, ground, .25), roads_label_major_halo: ground,
    state_label: mix(p.fg, ground, .4), state_label_halo: ground, country_label: mix(p.fg, ground, .25),
  });
  const layers = basemaps.layers("tiles", f, { lang: "en" });
  const out = path.join(__dirname, "..", "Aero", "Resources", "Map", "layers_" + name + ".json");
  fs.writeFileSync(out, JSON.stringify(layers));
  console.log(out, layers.length, "layers", fs.statSync(out).size, "bytes");
}
