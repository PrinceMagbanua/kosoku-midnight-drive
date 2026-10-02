"""Quick software-rendered preview of a livery on the modular cars (no Godot
needed). Renders each car's base + Preset_01 parts with the given texture
from a few angles into one contact-sheet PNG.

Usage: python3 tools/liveries/preview.py <texture.png> <out.png> [car ...]
"""
import json
import os
import sys

import numpy as np
import pygltflib
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PACK = os.path.join(ROOT, "assets/cars/Kosoku_Cars_GLB")
CARS = ["Sedan_01", "Sports_01", "Sports_02", "Hatch_01", "Muscle_01"]
VW, VH = int(os.environ.get("PREVIEW_W", 480)), int(os.environ.get("PREVIEW_H", 270))


def _acc(g, i):
    a = g.accessors[i]
    bv = g.bufferViews[a.bufferView]
    blob = g.binary_blob()
    dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8}[a.componentType]
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a.type]
    off = (bv.byteOffset or 0) + (a.byteOffset or 0)
    item = np.dtype(dt).itemsize * n
    stride = bv.byteStride or item
    if stride == item:
        return np.frombuffer(blob, dt, a.count * n, off).reshape(a.count, n)
    raw = np.frombuffer(blob, np.uint8, stride * (a.count - 1) + item, off)
    return np.stack([raw[k * stride:k * stride + item].view(dt) for k in range(a.count)])


def _node_matrix(nd):
    if nd.matrix:
        return np.array(nd.matrix, float).reshape(4, 4).T
    m = np.eye(4)
    if nd.scale:
        m = np.diag(list(nd.scale) + [1.0]) @ m
    if nd.rotation:
        x, y, z, w = nd.rotation
        r = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        rm = np.eye(4)
        rm[:3, :3] = r
        m = rm @ m
    if nd.translation:
        t = np.eye(4)
        t[:3, 3] = nd.translation
        m = t @ m
    return m


def load_tris(path):
    """-> (positions Nx3x3, uvs Nx3x2) for every non-glass triangle."""
    g = pygltflib.GLTF2().load(path)
    P, U = [], []

    def walk(ni, parent):
        nd = g.nodes[ni]
        m = parent @ _node_matrix(nd)
        if nd.mesh is not None:
            for p in g.meshes[nd.mesh].primitives:
                if p.material is not None and "Glass" in (g.materials[p.material].name or ""):
                    continue
                if p.attributes.TEXCOORD_0 is None:
                    continue
                pos = _acc(g, p.attributes.POSITION).astype(float)
                pos = (np.c_[pos, np.ones(len(pos))] @ m.T)[:, :3]
                uv = _acc(g, p.attributes.TEXCOORD_0).astype(float)
                idx = _acc(g, p.indices).flatten() if p.indices is not None else np.arange(len(pos))
                P.append(pos[idx].reshape(-1, 3, 3))
                U.append(uv[idx].reshape(-1, 3, 2))
        for c in nd.children or []:
            walk(c, m)

    for ni in g.scenes[g.scene or 0].nodes:
        walk(ni, np.eye(4))
    return np.concatenate(P), np.concatenate(U)


def car_tris(car):
    man = json.load(open(os.path.join(PACK, "cars_glb_manifest.json")))
    c = man["cars"][car]
    files = [os.path.join(PACK, c["base"])]
    for entry in c["presets"]["Preset_01"]:
        for slot, s in c["slots"].items():
            for var, f in s["variants"].items():
                if entry == f"{slot}_{var}":
                    files.append(os.path.join(PACK, f))
    ps, us = zip(*(load_tris(f) for f in files))
    return np.concatenate(ps), np.concatenate(us)


def look(eye, target):
    f = np.array(target, float) - eye
    f /= np.linalg.norm(f)
    r = np.cross(f, [0, 1, 0])
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return np.stack([r, u, -f])


def render(P, U, tex, eye, target=(0, 0.7, 0), fov=40):
    rot = look(np.array(eye, float), target)
    cam = (P - eye) @ rot.T  # camera space, looking down -z
    z = -cam[..., 2]
    f = 0.5 * VH / np.tan(np.radians(fov) / 2)
    sx = VW / 2 + cam[..., 0] / z * f
    sy = VH / 2 - cam[..., 1] / z * f
    n = np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0])
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-9
    light = np.array([0.4, 0.8, 0.45])
    light /= np.linalg.norm(light)
    shade = 0.45 + 0.55 * np.abs(n @ light)
    th, tw = tex.shape[:2]
    img = np.full((VH, VW, 3), (34, 36, 44), float)
    zbuf = np.full((VH, VW), np.inf)
    for i in range(len(P)):
        x, y, zz = sx[i], sy[i], z[i]
        if (zz <= 0.05).any():
            continue
        x0, x1 = int(max(0, np.floor(x.min()))), int(min(VW - 1, np.ceil(x.max())))
        y0, y1 = int(max(0, np.floor(y.min()))), int(min(VH - 1, np.ceil(y.max())))
        if x0 > x1 or y0 > y1:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        den = (y[1] - y[2]) * (x[0] - x[2]) + (x[2] - x[1]) * (y[0] - y[2])
        if abs(den) < 1e-9:
            continue
        a = ((y[1] - y[2]) * (gx - x[2]) + (x[2] - x[1]) * (gy - y[2])) / den
        b = ((y[2] - y[0]) * (gx - x[2]) + (x[0] - x[2]) * (gy - y[2])) / den
        c = 1 - a - b
        m = (a >= 0) & (b >= 0) & (c >= 0)
        if not m.any():
            continue
        iz = a / zz[0] + b / zz[1] + c / zz[2]
        depth = 1 / iz
        sub = zbuf[y0:y1 + 1, x0:x1 + 1]
        m &= depth < sub
        if not m.any():
            continue
        uu = (a * U[i, 0, 0] / zz[0] + b * U[i, 1, 0] / zz[1] + c * U[i, 2, 0] / zz[2]) * depth
        vv = (a * U[i, 0, 1] / zz[0] + b * U[i, 1, 1] / zz[1] + c * U[i, 2, 1] / zz[2]) * depth
        tx = np.clip((uu % 1.0) * tw, 0, tw - 1).astype(int)
        ty = np.clip((vv % 1.0) * th, 0, th - 1).astype(int)
        col = tex[ty, tx] * shade[i]
        sub[m] = depth[m]
        img[y0:y1 + 1, x0:x1 + 1][m] = col[m]
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


VIEWS = [
    ("left side", (-6.2, 1.1, 0.0)),
    ("right side", (6.2, 1.1, 0.0)),
    ("front 3/4", (3.9, 2.6, 5.0)),
    ("rear 3/4", (-3.9, 2.8, -5.0)),
]


def main():
    tex_path, out = sys.argv[1], sys.argv[2]
    cars = sys.argv[3:] or CARS
    tex = np.asarray(Image.open(tex_path).convert("RGB").resize((2048, 2048)), float)
    sheet = Image.new("RGB", (VW * len(VIEWS), VH * len(cars)))
    for r, car in enumerate(cars):
        P, U = car_tris(car)
        for c, (_, eye) in enumerate(VIEWS):
            sheet.paste(render(P, U, tex, eye), (c * VW, r * VH))
    sheet.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
