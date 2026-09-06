"""Original MIT native operators, authored entirely from mesh geometry.

Run Blender --background --python native-godot/tools/make_operators.py.
No downloaded anatomy, motion capture, textures, or proprietary source assets.
One skinned mesh, 18 bones, three materials, no bitmap textures or animation clips.
"""
import bpy
import math
import json
import struct
from pathlib import Path
from mathutils import Vector

OUT = Path(__file__).resolve().parents[1] / "assets" / "models"


def material(name, roughness, metallic=0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.use_backface_culling = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    color = mat.node_tree.nodes.new("ShaderNodeVertexColor")
    color.layer_name = "Color"
    mat.node_tree.links.new(color.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def finish(obj, name, color, bevel=0, lens=False):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    obj.name = name
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        mod = obj.modifiers.new("Rounded seams", "BEVEL")
        mod.width = bevel
        mod.segments = 1
        bpy.ops.object.modifier_apply(modifier=mod.name)
        mod = obj.modifiers.new("Weighted normals", "WEIGHTED_NORMAL")
        bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.materials.append(GLASS if lens else (HARDWARE if HARD else CLOTH))
    attr = obj.data.color_attributes.new(name="Color", type="FLOAT_COLOR", domain="CORNER")
    for polygon in obj.data.polygons:
        for loop in polygon.loop_indices:
            point = obj.data.vertices[obj.data.loops[loop].vertex_index].co
            # Subtle authored cloth shading, not an image texture.
            shade = 0.96 + 0.04 * math.sin(point.z * 39 + point.x * 17)
            attr.data[loop].color = (*[c * shade for c in color], 1)
    PARTS.append(obj)
    if BONE:
        group = obj.vertex_groups.new(name=BONE)
        group.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")
    return obj


def box(name, at, size, color, bevel=.009, lens=False):
    bpy.ops.mesh.primitive_cube_add(size=1, location=at)
    obj = bpy.context.object
    obj.scale = size
    return finish(obj, name, color, min(bevel, min(size) * .2), lens)


def oval(name, at, size, color):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=8, radius=1, location=at)
    obj = bpy.context.object
    obj.scale = size
    for face in obj.data.polygons:
        face.use_smooth = True
    return finish(obj, name, color)


def loft(name, sections, color, segments=16, folds=.018):
    """Closed, connected elliptical rings: cloth does not look like separate balls."""
    vertices, faces = [], []
    for i, (z, width, depth, center_y) in enumerate(sections):
        for j in range(segments):
            a = j * math.tau / segments
            ripple = 1 + folds * math.sin(a * 5 + i * 1.8)
            vertices.append((math.cos(a) * width * ripple, center_y + math.sin(a) * depth * ripple, z))
    for i in range(len(sections) - 1):
        for j in range(segments):
            a = i * segments + j
            b = i * segments + (j + 1) % segments
            faces.append((a, b, b + segments, a + segments))
    faces.append(tuple(reversed(range(segments))))
    faces.append(tuple((len(sections) - 1) * segments + j for j in range(segments)))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    for face in mesh.polygons:
        face.use_smooth = len(face.vertices) == 4
    return finish(obj, name, color)


def sleeve(name, start, end, width, depth, color):
    a, b = Vector(start), Vector(end)
    length = (b - a).length
    obj = loft(name, [(t * length, width * w, depth * d, 0) for t, w, d in
                     [(-.04, .78, .80), (.12, 1.0, 1.0), (.4, .96, .98),
                      (.68, .85, .88), (.89, .80, .78), (1.04, .75, .74)]], color)
    obj.location = a
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = (b - a).to_track_quat("Z", "Y")
    return obj


def limb(name, points, radii, bones, color):
    """Continuous cloth around a bent joint, with blended elbow/knee skinning."""
    global BONE
    BONE = None
    a, b, c = map(Vector, points)
    centers = [(a.lerp(b, t), radii[0] * (1-t) + radii[1]*t, t, 0)
               for t in [0, .22, .55, .85]]
    centers += [(b, radii[1], 1, 0)]
    centers += [(b.lerp(c, t), radii[1] * (1-t) + radii[2]*t, t, 1)
                for t in [.15, .45, .75, 1.02]]
    vertices, faces = [], []
    count = 12
    for i, (center, radius, t, half) in enumerate(centers):
        tangent = (centers[min(i+1, len(centers)-1)][0] - centers[max(0, i-1)][0]).normalized()
        x = tangent.cross(Vector((0, 1, 0))).normalized()
        y = tangent.cross(x).normalized()
        for j in range(count):
            angle = j * math.tau / count
            fold = 1 + .035 * math.sin(angle * 5 + i * 2)
            vertices.append(center + radius * fold * (x*math.cos(angle) + y*math.sin(angle)*.94))
    for i in range(len(centers)-1):
        for j in range(count):
            n = i*count+j
            next_n = i*count+(j+1)%count
            faces.append((n, next_n, next_n+count, n+count))
    faces += [tuple(reversed(range(count))), tuple((len(centers)-1)*count+j for j in range(count))]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    for face in mesh.polygons:
        face.use_smooth = len(face.vertices) == 4
    finish(obj, name, color)
    groups = [obj.vertex_groups.new(name=bone) for bone in bones]
    for i, (_, _, t, half) in enumerate(centers):
        weight = max(0, (t-.7)/.6) if half == 0 else min(1, .5+t/.6)
        indices = list(range(i*count, (i+1)*count))
        if weight < 1: groups[0].add(indices, 1-weight, 'REPLACE')
        if weight > 0: groups[1].add(indices, weight, 'REPLACE')


def build(team):
    global BONE, HARD, PARTS
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    PARTS, HARD = [], False
    ct = team == 'ct'
    shirt = (.035, .070, .095) if ct else (.23, .16, .095)
    pants = (.028, .048, .061) if ct else (.09, .102, .059)
    vest = (.035, .048, .046) if ct else (.092, .078, .047)
    straps = (.082, .103, .09) if ct else (.18, .15, .09)
    black, metal = (.010, .014, .016), (.034, .043, .046)
    mark = (.075, .32, .43) if ct else (.46, .16, .039)
    # Blender Z up / +Y forward. Export maps this to Godot Y up / -Z forward.
    joints = {
        'pelvis': ((0, 0, .94), (0, 0, 1.10), None),
        'spine': ((0, 0, 1.10), (0, 0, 1.32), 'pelvis'),
        'chest': ((0, 0, 1.32), (0, 0, 1.51), 'spine'),
        'neck': ((0, 0, 1.51), (0, 0, 1.60), 'chest'),
        'head': ((0, 0, 1.60), (0, 0, 1.80), 'neck'),
        'weapon': ((.13, .23, 1.42), (.13, .80, 1.42), 'chest'),
    }
    for side, sign in [('l', -1), ('r', 1)]:
        shoulder = (sign*.215, 0, 1.43)
        elbow = (-.12, .21, 1.225) if sign < 0 else (.32, .05, 1.16)
        wrist = (.10, .42, 1.36) if sign < 0 else (.13, .23, 1.32)
        hip, knee, ankle = (sign*.105, 0, .94), (sign*.115, .04, .52), (sign*.12, -.012, .14)
        joints.update({
            'upperarm_'+side: (shoulder, elbow, 'chest'),
            'forearm_'+side: (elbow, wrist, 'upperarm_'+side),
            'hand_'+side: (wrist, tuple(Vector(wrist)+Vector((0, .075, 0))), 'forearm_'+side),
            'thigh_'+side: (hip, knee, 'pelvis'),
            'shin_'+side: (knee, ankle, 'thigh_'+side),
            'foot_'+side: (ankle, (sign*.12, .16, .07), 'shin_'+side),
        })
    armature = bpy.data.armatures.new('OperatorSkeleton')
    rig = bpy.data.objects.new(team+'_operator', armature)
    bpy.context.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    for name, (head, tail, parent) in joints.items():
        bone = armature.edit_bones.new(name)
        bone.head, bone.tail = head, tail
        if parent: bone.parent = armature.edit_bones[parent]
    bpy.ops.object.mode_set(mode='OBJECT')
    BONE = 'spine'
    torso = loft('Tailored jacket', [(.89,.15,.115,0), (1.02,.17,.125,0),
        (1.17,.19,.14,0), (1.34,.22,.14,-.012), (1.43,.235,.125,-.015),
        (1.49,.155,.095,0)], shirt)
    torso.vertex_groups.clear()
    groups = {name: torso.vertex_groups.new(name=name) for name in ['pelvis','spine','chest']}
    for vertex in torso.data.vertices:
        t = max(0, min(2, (vertex.co.z-1.01)/.16))
        first, second = ('pelvis', 'spine') if t < 1 else ('spine', 'chest')
        fraction = t if t < 1 else t-1
        if fraction < 1: groups[first].add([vertex.index], 1-fraction, 'REPLACE')
        if fraction > 0: groups[second].add([vertex.index], fraction, 'REPLACE')
    BONE = 'chest'
    # Chamfered carrier follows the torso, not a large flat floating block.
    loft('Plate carrier', [(1.12,.163,.153,0), (1.28,.185,.167,0),
         (1.40,.172,.145,-.006), (1.445,.122,.13,-.008)], vest, segments=12, folds=0)
    box('Back pouch', (0,-.195,1.28), (.21,.095,.29), straps, .018)
    box('Pouch flap', (0,-.249,1.37), (.20,.016,.06), vest)
    for x in [-.11, 0, .11]:
        box('Magazine pouch', (x,.178,1.185), (.092,.075,.16), straps)
        box('Retention strap', (x,.221,1.21), (.02,.009,.075), vest, .002)
    for z in [1.29,1.33]: box('Webbing', (0,.167,z), (.29,.016,.014), straps, .002)
    box('Unit patch', (0,.155,1.388), (.10,.015,.033), mark, .003)
    for sign in [-1,1]: box('Shoulder strap', (sign*.15,0,1.444), (.052,.25,.041), straps)
    BONE = 'pelvis'
    loft('Belt', [(.973,.178,.128,0), (1.017,.178,.128,0)], black, segments=16, folds=0)
    box('Buckle',(0,.14,.993),(.05,.018,.035),metal,.003)
    for sign in [-1,1]: box('Belt pouch',(sign*.19,-.005,1.015),(.075,.12,.12),straps)
    for side, sign in [('l',-1),('r',1)]:
        shoulder, elbow = joints['upperarm_'+side][:2]
        wrist = joints['hand_'+side][0]
        limb('Articulated sleeve', [shoulder,elbow,wrist], [.088,.071,.052],
             ['upperarm_'+side,'forearm_'+side],shirt)
        BONE = 'upperarm_'+side
        oval('Rounded shoulder seam',shoulder,(.085,.083,.087),shirt)
        BONE = 'hand_'+side
        oval('Glove', tuple(Vector(wrist)+Vector((0,.025,0))), (.048,.065,.041), black)
        hip, knee = joints['thigh_'+side][:2]
        ankle = joints['foot_'+side][0]
        limb('Articulated trousers',[hip,knee,ankle],[.105,.080,.065],
             ['thigh_'+side,'shin_'+side],pants)
        BONE = 'thigh_'+side
        box('Cargo pocket',(sign*.197,-.005,.74),(.055,.135,.145),shirt)
        box('Pocket flap',(sign*.225,-.005,.79),(.014,.13,.035),straps,.003)
        BONE = 'shin_'+side
        box('Knee pad',(sign*.115,.111,.515),(.123,.043,.125),vest,.012)
        BONE, HARD = 'foot_'+side, True
        box('Boot ankle',(sign*.12,-.012,.14),(.143,.15,.175),black,.018)
        box('Boot toe',(sign*.12,.059,.063),(.152,.254,.11),metal,.022)
        box('Rubber sole',(sign*.12,.058,.018),(.156,.257,.03),black,.006)
        HARD = False
    BONE = 'neck'
    loft('Raised fabric collar',[(1.465,.092,.081,0),(1.51,.078,.075,0),
         (1.56,.069,.067,0)],straps,segments=12,folds=.015)
    BONE = 'head'
    loft('Fitted head wrap',[(1.53,.056,.058,0),(1.585,.075,.077,.004),
         (1.635,.097,.095,0),(1.70,.108,.103,-.005),
         (1.755,.094,.091,-.009),(1.795,.05,.05,-.01)],black if ct else straps,
         segments=16,folds=0)
    loft('Lower face scarf',[(1.555,.068,.071,.002),(1.61,.090,.092,.002),
         (1.655,.102,.102,-.003)],shirt if ct else vest,segments=16,folds=.015)
    oval('Helmet' if ct else 'Soft cap',(0,-.016,1.752),(.14 if ct else .116,.129,.07),vest)
    if not ct: box('Cap peak',(0,.111,1.743),(.17,.115,.017),straps,.004)
    HARD = True
    box('Goggle frame',(0,.103,1.691),(.192,.038,.048),metal,.008)
    box('Coated goggles',(0,.125,1.693),(.171,.011,.03),(.055,.092,.087),.002,True)
    if ct:
        for sign in [-1,1]: box('Hearing protection',(sign*.111,-.015,1.666),(.044,.073,.085),metal)
        box('Helmet mount',(0,.105,1.757),(.044,.018,.035),black,.003)
    BONE = 'weapon'
    box('Receiver',(.13,.265,1.42),(.062,.235,.078),metal)
    box('Stock',(.13,.057,1.422),(.053,.205,.074),black)
    box('Pistol grip',(.13,.23,1.344),(.037,.059,.11),black)
    box('Fore end',(.13,.47,1.42),(.058,.21,.063),metal if ct else (.16,.07,.026))
    box('Barrel',(.13,.674,1.425),(.022,.219,.022),black,.002)
    box('Front sight',(.13,.625,1.457),(.024,.023,.055),metal,.002)
    box('Rear sight',(.13,.212,1.47),(.036,.033,.022),black,.002)
    for i in range(4):
        mag=box('Magazine',(.13,.335+(0 if ct else i*.007),1.356-i*.031),(.042,.06,.037),black,.002)
        if not ct: mag.rotation_euler.x=-i*.055
    bpy.ops.object.select_all(action='DESELECT')
    for part in PARTS: part.select_set(True)
    bpy.context.view_layer.objects.active = PARTS[0]
    bpy.ops.object.join()
    mesh = bpy.context.object
    mesh.name = 'SkinnedOperator'
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    mesh.parent = rig
    modifier = mesh.modifiers.new('Operator skin','ARMATURE')
    modifier.object = rig
    bpy.ops.object.select_all(action='DESELECT')
    mesh.select_set(True)
    rig.select_set(True)
    destination = OUT / (team+'_operator.glb')
    bpy.ops.export_scene.gltf(filepath=str(destination),export_format='GLB',use_selection=True,
        export_animations=False,export_cameras=False,export_lights=False,export_texcoords=False,
        export_vertex_color='MATERIAL',export_skins=True)
    data = destination.read_bytes()
    document = json.loads(data[20:20+struct.unpack_from('<I',data,12)[0]])
    triangles = sum(document['accessors'][p['indices']]['count']//3 for m in document['meshes'] for p in m['primitives'])
    print('SKINNED_OPERATOR',team,'triangles',triangles,'surfaces',sum(len(m['primitives']) for m in document['meshes']),
          'bones',len(document['skins'][0]['joints']),'bytes',len(data))
    assert len(document['meshes']) == 1 and len(document['skins'][0]['joints']) == 18
    assert triangles <= 8500 and len(data) <= 650000 and not document.get('images')


if __name__ == '__main__':
    CLOTH = material('Original woven fabric',.85)
    HARDWARE = material('Original hardware',.57,.15)
    GLASS = material('Original coated goggles',.26,.35)
    OUT.mkdir(parents=True,exist_ok=True)
    build('ct')
    build('t')
