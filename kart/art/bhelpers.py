# Blender modeling helpers for Loop GP assets. exec() this file before scripts.
import bpy, bmesh, math
from mathutils import Vector

scn = bpy.context.scene


def srgb(h):
    h = h.lstrip('#')
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c)


def newmat(name, hexcol, rough=0.8):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*srgb(hexcol), 1)
    b.inputs["Roughness"].default_value = rough
    m.diffuse_color = (*srgb(hexcol), 1)
    return m


def link(ob, mat_name=None, smooth=True, parent=None):
    scn.collection.objects.link(ob)
    if mat_name:
        ob.data.materials.append(bpy.data.materials[mat_name])
    if smooth and ob.type == 'MESH':
        for p in ob.data.polygons:
            p.use_smooth = True
    if parent:
        ob.parent = parent
    return ob


def sphere(name, r, loc, mat_name, scale=(1, 1, 1), segs=24, rings=12, parent=None):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me), mat_name, parent=parent)
    ob.location = loc
    ob.scale = scale
    return ob


def cyl(name, r, depth, loc, mat_name, rot=(0, 0, 0), segs=24, r2=None, parent=None):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r if r2 is None else r2, depth=depth)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me), mat_name, parent=parent)
    ob.location = loc
    ob.rotation_euler = rot
    return ob


def tube(name, a, b, r, mat_name, segs=8, parent=None):
    a = Vector(a)
    b = Vector(b)
    d = b - a
    ob = cyl(name, r, d.length, (a + b) / 2, mat_name, segs=segs, parent=parent)
    ob.rotation_euler = d.to_track_quat('Z', 'Y').to_euler()
    return ob


def rbox(name, size, loc, mat_name, bevel=0.05, segs=3, rot=(0, 0, 0), parent=None):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me), mat_name, parent=parent)
    ob.location = loc
    ob.rotation_euler = rot
    if bevel > 0:
        md = ob.modifiers.new("Bevel", "BEVEL")
        md.width = bevel
        md.segments = segs
        md.limit_method = 'NONE'
    return ob


def skin_mesh(name, nodes, edges, mat_name, root, parent=None, subsurf=2):
    """nodes: {key: ((x,y,z), radius or (rx, ry))}; edges: [(a, b)]"""
    keys = list(nodes)
    me = bpy.data.meshes.new(name)
    me.from_pydata([nodes[k][0] for k in keys], [(keys.index(a), keys.index(b)) for a, b in edges], [])
    ob = link(bpy.data.objects.new(name, me), mat_name, parent=parent)
    sk = ob.modifiers.new("Skin", "SKIN")
    sk.use_smooth_shade = True
    for i, k in enumerate(keys):
        r = nodes[k][1]
        sv = me.skin_vertices[0].data[i]
        sv.radius = r if isinstance(r, tuple) else (r, r)
        if k == root:
            sv.use_root = True
    if subsurf:
        ss = ob.modifiers.new("Subsurf", "SUBSURF")
        ss.levels = subsurf
        ss.render_levels = subsurf
    return ob


def apply_mods(ob):
    bpy.ops.object.select_all(action='DESELECT')
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    for m in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)


def join(objs, name, parent=None):
    dg = bpy.context.evaluated_depsgraph_get()
    new = []
    for o in objs:
        me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
        me.transform(o.matrix_world)
        ob = bpy.data.objects.new(o.name + "_f", me)
        scn.collection.objects.link(ob)
        new.append(ob)
    for o in objs:
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.object.select_all(action='DESELECT')
    for o in new:
        o.select_set(True)
    bpy.context.view_layer.objects.active = new[0]
    bpy.ops.object.join()
    j = bpy.context.view_layer.objects.active
    j.name = name
    if parent:
        pm = parent.matrix_world.copy()
        j.data.transform(pm.inverted())
        j.parent = parent
        j.matrix_world = pm
    return j


def export(path, objs):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.hide_set(False)
        o.select_set(True)
        for c in o.children_recursive:
            c.hide_set(False)
            c.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', use_selection=True, export_apply=True,
                              export_cameras=False, export_lights=False)
