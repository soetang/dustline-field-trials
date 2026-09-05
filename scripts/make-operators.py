"""Author compact, original GLB operators. Run with Blender --background --python.

No downloaded character art or textures. Geometry is merged into a body and two
hip-pivoted legs; vertex colour keeps material/draw-call counts low in WebGL.
"""
import bpy
import math
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets' / 'models'
OUT.mkdir(parents=True, exist_ok=True)

def material(name, roughness, metallic):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.use_backface_culling = True
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Roughness'].default_value = roughness
    bsdf.inputs['Metallic'].default_value = metallic
    colour = mat.node_tree.nodes.new('ShaderNodeVertexColor')
    colour.layer_name = 'Color'
    mat.node_tree.links.new(colour.outputs['Color'], bsdf.inputs['Base Color'])
    return mat

CLOTH = material('Equipment | matte woven finish', .76, .03)
GLASS = material('Ballistic goggles | coated lens', .23, .65)

def finish(obj, name, colour, mat=CLOTH, bevel=0):
    obj.name = name
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        mod = obj.modifiers.new('Soft manufactured edges', 'BEVEL')
        mod.width = bevel
        mod.segments = 2
        bpy.ops.object.modifier_apply(modifier=mod.name)
        mod = obj.modifiers.new('Weighted face normals', 'WEIGHTED_NORMAL')
        bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    attr = obj.data.color_attributes.new(name='Color', type='FLOAT_COLOR', domain='CORNER')
    for datum in attr.data:
        datum.color = (*colour, 1)
    return obj

def box(name, pos, size, colour, bevel=.012, mat=CLOTH):
    bpy.ops.mesh.primitive_cube_add(size=1, location=pos)
    obj = bpy.context.object
    obj.scale = size
    return finish(obj, name, colour, mat, min(bevel, min(size) * .23))

def oval(name, pos, size, colour):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=1, location=pos)
    obj = bpy.context.object
    obj.scale = size
    for face in obj.data.polygons:
        face.use_smooth = True
    return finish(obj, name, colour)

def link(name, start, end, radii, colour):
    a, b = Vector(start), Vector(end)
    obj = oval(name, (a+b)/2, (radii[0], radii[1], (a-b).length/2 + radii[0]*.25), colour)
    obj.rotation_mode = 'QUATERNION'
    obj.rotation_quaternion = (b-a).to_track_quat('Z', 'Y')
    return obj

def join(objects, name, parent):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    obj = bpy.context.object
    obj.name = name
    # Bake placement into vertices, so pivots are explicit and reproducible.
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.parent = parent
    obj.matrix_parent_inverse = parent.matrix_world.inverted()
    return obj

def empty(name, pos=(0, 0, 0), parent=None):
    obj = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(obj)
    obj.location = pos
    obj.parent = parent
    bpy.context.view_layer.update()
    return obj

def operator(team):
    ct = team == 'ct'
    uniform = (.075, .17, .23) if ct else (.36, .25, .13)
    fabric = tuple(c * 1.28 for c in uniform)
    plate = (.11, .16, .16) if ct else (.19, .20, .12)
    webbing = (.23, .29, .27) if ct else (.39, .34, .20)
    black = (.025, .033, .037)
    trim = (.09, .105, .11)
    team_mark = (.15, .65, .73) if ct else (.92, .39, .075)
    root = empty(team + '_operator')
    parts = [
        oval('Fitted field jacket', (0, 0, 1.27), (.24, .145, .32), uniform),
        box('Plate carrier', (0, .026, 1.29), (.44, .32, .40), plate, .03),
        box('Rear armour panel', (0, -.172, 1.30), (.33, .075, .36), plate, .025),
        box('Hydration pack', (0, -.235, 1.27), (.235, .10, .34), webbing, .025),
        oval('Hip webbing', (0, -.01, .97), (.19, .13, .13), uniform),
        box('Duty belt', (0, .015, 1.025), (.385, .27, .065), black),
        box('Belt buckle', (0, .163, 1.025), (.065, .025, .051), trim),
        oval('Collar', (0, 0, 1.535), (.103, .10, .09), webbing),
        oval('Balaclava', (0, .003, 1.692), (.139, .122, .176), black),
        oval('Helmet shell', (0, -.008, 1.79), (.17, .146, .109), plate),
        box('Helmet front mount', (0, .137, 1.818), (.067, .025, .058), black),
        box('Goggle frame', (0, .119, 1.719), (.26, .059, .089), trim),
        box('Coated lenses', (0, .154, 1.725), (.218, .019, .051), (.16, .29, .30), .01, GLASS),
        box('Face wrap seam', (0, .122, 1.654), (.16, .021, .046), plate),
        box('Team identifier', (0, .194, 1.429), (.17, .018, .052), team_mark),
        box('Identifier stripe', (0, .207, 1.429), (.106, .009, .009), (.78, .83, .73), .001),
    ]
    for side in [-1, 1]:
        parts += [
            box('Shoulder harness', (side*.172, -.008, 1.478), (.066, .325, .065), webbing),
            oval('Shoulder', (side*.249, .0, 1.439), (.094, .098, .11), fabric),
            box('Comms ear cup', (side*.145, -.01, 1.718), (.057, .093, .11), trim),
            box('Helmet accessory rail', (side*.16, -.018, 1.815), (.023, .13, .031), black, .004),
            box('Side utility pouch', (side*.212, -.013, 1.07), (.094, .11, .15), webbing),
            box('Upper arm identifier', (side*.28, .04, 1.37), (.055, .12, .065), team_mark),
        ]
    for x in [-.13, 0, .13]:
        parts += [box('Magazine pouch', (x, .204, 1.235), (.103, .084, .17), webbing),
                  box('Pouch retention tab', (x, .251, 1.26), (.021, .009, .081), plate, .002)]
    for z in [1.32, 1.355]:
        parts.append(box('Carrier stitching', (0, .195, z), (.32, .011, .012), webbing, .002))
    parts += [
        link('Right upper sleeve', (.25, .015, 1.43), (.31, .065, 1.17), (.081, .078), uniform),
        link('Right forearm', (.31, .065, 1.17), (.125, .29, 1.285), (.062, .057), fabric),
        oval('Trigger glove', (.125, .30, 1.285), (.065, .055, .064), black),
        link('Left upper sleeve', (-.25, .0, 1.43), (-.28, .11, 1.17), (.081, .078), uniform),
        link('Left forearm', (-.28, .11, 1.17), (.04, .53, 1.30), (.057, .054), fabric),
        oval('Support glove', (.04, .52, 1.30), (.061, .06, .051), black),
        box('Carbine receiver', (.09, .31, 1.335), (.075, .285, .095), trim),
        box('Stock', (.09, .07, 1.34), (.065, .22, .087), black),
        box('Handguard', (.09, .555, 1.347), (.071, .23, .075), trim),
        box('Barrel', (.09, .76, 1.35), (.023, .20, .023), black, .004),
        box('Magazine', (.09, .325, 1.222), (.051, .069, .16), black),
        box('Optic base', (.09, .30, 1.403), (.055, .088, .044), black),
        box('Optic lens', (.09, .351, 1.411), (.034, .015, .027), (.11, .23, .23), .003, GLASS),
    ]
    for y in [.49, .54, .59, .64]:
        parts.append(box('Handguard vent', (.13, y, 1.353), (.008, .026, .018), black, .002))
    join(parts, 'equipped_body', root)
    for side, name in [(-1, 'leg_l'), (1, 'leg_r')]:
        x = side * .11
        joint = empty(name, (x, 0, .92), root)
        leg = [
            link('Trouser thigh', (x, 0, .91), (x*1.1, .015, .52), (.099, .093), uniform),
            link('Trouser shin', (x*1.1, .015, .50), (x*1.15, -.014, .14), (.081, .075), fabric),
            box('Knee pad', (x*1.1, .083, .50), (.127, .067, .147), plate, .025),
            box('Boot upper', (x*1.15, -.01, .15), (.155, .18, .195), black, .025),
            box('Boot toe', (x*1.15, .065, .065), (.165, .265, .12), trim, .03),
            box('Boot sole', (x*1.15, .062, .024), (.17, .269, .035), black, .008),
            box('Cargo pocket', (x + side*.079, -.016, .73), (.061, .15, .176), fabric),
        ]
        join(leg, name + '_equipment', joint)
    root.location.z = -1.05  # The renderer's operator pivot is at waist height.
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action='DESELECT')
    root.select_set(True)
    for obj in root.children_recursive:
        obj.select_set(True)
    props = bpy.ops.export_scene.gltf.get_rna_type().properties
    options = dict(filepath=str(OUT / (team + '_operator.glb')), export_format='GLB', use_selection=True,
                   export_animations=False, export_cameras=False, export_lights=False)
    if 'export_vertex_color' in props:
        options['export_vertex_color'] = 'MATERIAL'
    else:
        options['export_colors'] = True
    bpy.ops.export_scene.gltf(**options)
    print('EXPORTED', team, 'triangles', sum(len(o.data.polygons) for o in root.children_recursive if o.type == 'MESH'))
    return root

def main():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    ct = operator('ct')
    ct.location = (-.55, 0, 0)
    t = operator('t')
    t.location = (.55, 0, 0)
    t.rotation_euler.z = math.radians(-16)
    # A reproducible CPU preview for visual inspection, not an in-game bitmap asset.
    bpy.ops.mesh.primitive_plane_add(size=200)
    floor = bpy.context.object
    floor.data.materials.append(bpy.data.materials.new('Preview ground'))
    floor.data.materials[0].diffuse_color = (.16, .17, .17, 1)
    bpy.ops.object.camera_add(location=(2.65, 5.1, 2.2))
    camera = bpy.context.object
    camera.rotation_euler = (Vector((0, 0, .95)) - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.type = 'ORTHO'
    camera.data.ortho_scale = 2.8
    bpy.context.scene.camera = camera
    for location, power, size in [((1, 4, 5), 650, 4), ((-3, 1, 3), 450, 3), ((0, -3, 4), 700, 3)]:
        bpy.ops.object.light_add(type='AREA', location=location)
        light = bpy.context.object
        light.data.energy = power
        light.data.shape = 'DISK'
        light.data.size = size
        light.rotation_euler = (Vector((0, 0, 1)) - light.location).to_track_quat('-Z', 'Y').to_euler()
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 12
    scene.world.color = (.23, .23, .23)
    scene.render.resolution_x, scene.render.resolution_y = 900, 760
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.filepath = str(ROOT / 'artifacts' / 'operator-preview.png')
    bpy.ops.render.render(write_still=True)

if __name__ == '__main__':
    main()
