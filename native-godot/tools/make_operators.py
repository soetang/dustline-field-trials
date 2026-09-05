"""Original MIT native operators, authored entirely from mesh geometry.

Run Blender --background --python native-godot/tools/make_operators.py.
No downloaded anatomy, motion capture, textures, or proprietary source assets.
The foot-origin hierarchy has separate hips/knees and an upper-body aim pivot.
"""
import bpy
import math
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
        mod.segments = 2
        bpy.ops.object.modifier_apply(modifier=mod.name)
        mod = obj.modifiers.new("Weighted normals", "WEIGHTED_NORMAL")
        bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.materials.append(GLASS if lens else CLOTH)
    attr = obj.data.color_attributes.new(name="Color", type="FLOAT_COLOR", domain="CORNER")
    for polygon in obj.data.polygons:
        for loop in polygon.loop_indices:
            point = obj.data.vertices[obj.data.loops[loop].vertex_index].co
            # Subtle authored cloth shading, not an image texture.
            shade = 0.96 + 0.04 * math.sin(point.z * 39 + point.x * 17)
            attr.data[loop].color = (*[c * shade for c in color], 1)
    return obj


def box(name, at, size, color, bevel=.009, lens=False):
    bpy.ops.mesh.primitive_cube_add(size=1, location=at)
    obj = bpy.context.object
    obj.scale = size
    return finish(obj, name, color, min(bevel, min(size) * .2), lens)


def oval(name, at, size, color):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=1, location=at)
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


def joint(name, at=(0, 0, 0), parent=None):
    node = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(node)
    node.parent = parent
    bpy.context.view_layer.update()
    node.matrix_world.translation = Vector(at)
    bpy.context.view_layer.update()
    return node


def join(parts, name, parent):
    bpy.ops.object.select_all(action="DESELECT")
    for part in parts:
        part.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    obj = bpy.context.object
    obj.name = name
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.parent = parent
    obj.matrix_parent_inverse = parent.matrix_world.inverted()
    return obj


def build(team):
    ct = team == "ct"
    shirt = (.035, .065, .085) if ct else (.23, .16, .095)
    pants = (.025, .042, .054) if ct else (.09, .102, .059)
    vest = (.040, .058, .058) if ct else (.092, .078, .047)
    straps = (.082, .103, .09) if ct else (.18, .15, .09)
    black = (.010, .014, .016)
    metal = (.034, .043, .046)
    skin = (.28, .15, .078)
    mark = (.075, .32, .43) if ct else (.46, .16, .039)
    root = joint(team + "_operator")
    upper = joint("upper_body", (0, 0, 1.02), root)
    head = joint("head_aim", (0, 0, 1.53), upper)
    weapon = joint("weapon_aim", (.09, .10, 1.37), upper)
    torso = [
        loft("Fitted jacket", [(.91, .16, .12, 0), (1.02, .185, .125, 0),
             (1.17, .20, .145, 0), (1.34, .235, .145, -.015),
             (1.44, .24, .13, -.02), (1.50, .17, .115, -.015)], shirt),
        box("Front plate panel", (0, .134, 1.28), (.365, .105, .365), vest, .024),
        box("Back plate panel", (0, -.148, 1.28), (.33, .09, .36), vest, .020),
        box("Fabric hydration pouch", (0, -.218, 1.26), (.22, .11, .31), straps, .022),
        box("Pouch flap", (0, -.28, 1.37), (.21, .016, .073), vest),
        box("Pouch pull", (.06, -.296, 1.33), (.012, .012, .059), black, .002),
        box("Web belt", (0, 0, 1.012), (.38, .268, .060), black),
        box("Buckle", (0, .149, 1.012), (.056, .026, .046), metal),
        oval("High collar", (0, 0, 1.51), (.105, .095, .054), straps),
        box("Unit patch", (0, .192, 1.393), (.11, .014, .042), mark),
    ]
    for x in [-.124, 0, .124]:
        torso += [box("Magazine pouch", (x, .207, 1.19), (.102, .082, .175), straps),
                  box("Retention strap", (x, .252, 1.214), (.020, .009, .083), vest, .002)]
    for z in [1.295, 1.332]:
        torso.append(box("Webbing row", (0, .197, z), (.31, .012, .015), straps, .002))
    for side in [-1, 1]:
        torso += [box("Shoulder strap", (side * .153, -.014, 1.455), (.056, .285, .060), straps),
                  box("Hip utility pouch", (side * .207, -.015, 1.055), (.080, .13, .13), straps),
                  sleeve("Shoulder sleeve", (side * .205, -.018, 1.444),
                         (side * .307, .13, 1.205), .090, .087, shirt),
                  box("Sleeve patch", (side * .295, .045, 1.371), (.026, .08, .067), mark, .004)]
    torso += [sleeve("Trigger forearm", (.307, .13, 1.205), (.105, .285, 1.332), .073, .067, shirt),
              sleeve("Support forearm", (-.307, .13, 1.205), (.015, .54, 1.335), .070, .065, shirt),
              box("Trigger glove", (.10, .295, 1.335), (.10, .09, .082), black, .014),
              box("Support glove", (.012, .53, 1.338), (.105, .095, .071), black, .012)]
    join(torso, "jacket_and_equipment", upper)
    face = [oval("Head wrap" if ct else "Face", (0, -.003, 1.667), (.119, .110, .153), black if ct else skin),
            oval("Neck", (0, -.007, 1.535), (.070, .069, .082), shirt if ct else skin),
            box("Eye recess", (0, .109, 1.698), (.196, .018, .039), skin if ct else black, .004)]
    if ct:
        face += [oval("Helmet shell", (0, -.017, 1.748), (.153, .139, .075), vest),
                 box("Helmet rim", (0, -.005, 1.744), (.294, .264, .025), straps),
                 box("Goggle bridge", (0, .126, 1.703), (.217, .035, .055), metal),
                 box("Tinted goggles", (0, .148, 1.706), (.186, .010, .032), (.056, .093, .09), .003, True),
                 box("Face wrap fold", (0, .105, 1.630), (.162, .026, .054), shirt),
                 box("Helmet mount", (0, .124, 1.759), (.056, .02, .041), black)]
        for side in [-1, 1]:
            face.append(box("Ear protection", (side * .12, -.02, 1.679), (.05, .081, .092), metal))
    else:
        face += [oval("Wrapped head scarf", (0, -.018, 1.77), (.129, .116, .061), straps),
                 box("Scarf band", (0, .074, 1.752), (.215, .115, .035), vest),
                 oval("Beard line", (0, .039, 1.604), (.094, .079, .067), (.029, .022, .016)),
                 box("Nose", (0, .115, 1.667), (.033, .036, .052), skin, .006)]
        for side in [-1, 1]:
            face += [box("Eye", (side * .044, .121, 1.699), (.018, .008, .009), black, .001),
                     box("Brow", (side * .045, .119, 1.714), (.052, .01, .012), black, .001)]
    join(face, "head_equipment", head)
    gun = [box("Receiver", (.09, .323, 1.377), (.069, .27, .087), metal),
           box("Stock", (.09, .093, 1.378), (.060, .235, .080), black),
           box("Grip", (.09, .264, 1.305), (.043, .065, .109), black),
           box("Fore end", (.09, .552, 1.389), (.065, .225, .068), metal if ct else (.16, .070, .026)),
           box("Barrel", (.09, .752, 1.397), (.022, .215, .022), black, .003),
           box("Front sight", (.09, .69, 1.436), (.026, .019, .061), metal, .002),
           box("Rear sight", (.09, .25, 1.434), (.046, .04, .035), black, .004)]
    for i in range(4):
        mag = box("Magazine section", (.09, .369 + (0 if ct else i * .009), 1.311 - i * .034),
                  (.049, .067, .042), black, .003)
        if not ct:
            mag.rotation_euler.x = i * -.055
        gun.append(mag)
    for y in [.475, .52, .565, .61]:
        gun.append(box("Rail", (.09, y, 1.432), (.067, .018, .012), black, .002))
    join(gun, "carbine" if ct else "rifle", weapon)
    joint("muzzle_socket", (.09, .863, 1.397), weapon)
    for side, name in [(-1, "leg_l"), (1, "leg_r")]:
        x = side * .105
        hip = joint(name, (x, 0, .94), root)
        knee = joint(name + "_knee", (x * 1.10, .019, .49), hip)
        thigh = [sleeve("Trouser thigh", (x, 0, .94), (x * 1.10, .019, .48), .109, .105, pants),
                 box("Cargo pocket", (x + side * .086, -.017, .704), (.064, .145, .155), shirt),
                 box("Pocket flap", (x + side * .119, -.014, .765), (.013, .142, .035), straps, .003)]
        join(thigh, name + "_thigh", hip)
        shin = [sleeve("Trouser calf", (x * 1.10, .019, .50), (x * 1.15, -.02, .13), .087, .084, pants),
                box("Knee pad", (x * 1.10, .091, .486), (.125, .061, .129), vest, .017),
                box("Boot ankle", (x * 1.15, -.018, .125), (.154, .164, .186), black, .017),
                box("Boot toe", (x * 1.15, .061, .069), (.162, .258, .117), metal, .02),
                box("Rubber sole", (x * 1.15, .058, .020), (.166, .263, .033), black, .006)]
        for z in [.13, .16, .19]:
            shin.append(box("Boot lace", (x * 1.15, .071, z), (.075, .012, .012), straps, .002))
        join(shin, name + "_shin", knee)
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    root.select_set(True)
    for node in root.children_recursive:
        node.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(OUT / (team + "_operator.glb")), export_format="GLB",
                             use_selection=True, export_animations=False, export_cameras=False,
                             export_lights=False, export_vertex_color="MATERIAL")
    triangles = sum(len(p.vertices) - 2 for o in root.children_recursive if o.type == "MESH" for p in o.data.polygons)
    print("NATIVE_OPERATOR", team, "triangles", triangles, "bytes", (OUT / (team + "_operator.glb")).stat().st_size)


if __name__ == "__main__":
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    CLOTH = material("Original woven fabric and equipment", .82)
    GLASS = material("Original coated goggles", .28, .35)
    OUT.mkdir(parents=True, exist_ok=True)
    build("ct")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    build("t")
