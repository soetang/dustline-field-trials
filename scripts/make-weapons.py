"""Original first-person GLBs with distinct silhouettes and named moving parts.

Run in Blender's background mode. Reuses the operator modelling helpers; exports
geometry, not bitmap approximations. Blender + the existing glTF loader suffice.
"""
import bpy
import math
import importlib.util
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('modelkit', ROOT / 'scripts' / 'make-operators.py')
kit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kit)
box, oval, link, join, empty = kit.box, kit.oval, kit.link, kit.join, kit.empty
METAL = kit.material('Weapon | anodised metal', .34, .78)
LENS = kit.material('Optics | coated glass', .13, .72)
POLYMER = kit.CLOTH
GUN = (.055, .069, .075)
EDGE = (.105, .12, .126)
BLACK = (.018, .025, .028)
TAN = (.24, .18, .10)
STEEL = (.30, .32, .33)
GLOVE = (.042, .058, .061)

def block(name, pos, size, colour=GUN, bevel=.01, mat=METAL):
    return box(name, pos, size, colour, bevel, mat)

def tube(name, pos, radius, length, colour=GUN, axis='Y', mat=METAL):
    bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=radius, depth=length, location=pos)
    obj = bpy.context.object
    if axis == 'Y': obj.rotation_euler.x = math.pi / 2
    if axis == 'X': obj.rotation_euler.y = math.pi / 2
    return kit.finish(obj, name, colour, mat, min(radius*.17, .003))

def section(objects, name, root, pivot=(0,0,0)):
    bone = empty(name, pivot, root)
    join(objects, name + '_mesh', bone)
    return bone

def hand(root, side, support, pistol):
    # Positive Blender Y becomes the game's forward -Z after glTF conversion.
    if support:
        palm = (-.05, .025, -.225) if pistol else (-.025, .47, -.073)
        start = (-.30, -.39, -.31)
    else:
        palm = (.055, -.055, -.16)
        start = (.34, -.44, -.30)
    sleeve_end = Vector(start).lerp(Vector(palm), .42)
    pieces = [link('Field sleeve', start, sleeve_end, (.085, .074), (.055, .13, .18)),
              link('Gloved wrist', sleeve_end, palm, (.065, .053), GLOVE),
              oval('Palm', palm, (.068, .087, .052), GLOVE)]
    for finger in range(4):
        x = palm[0] + (finger-1.5)*.027
        # Curled fingers and knuckle pads make the close-up hands readable.
        pieces.append(oval('Curled finger', (x, palm[1]+.055, palm[2]-.022), (.015,.052,.025), GLOVE))
        pieces.append(block('Knuckle armour', (x,palm[1]+.005,palm[2]+.048), (.020,.030,.011), EDGE, .004, POLYMER))
    pieces.append(link('Thumb', (palm[0] + .055*side,palm[1]-.014,palm[2]),
                       (palm[0]+.07*side,palm[1]+.048,palm[2]+.013), (.021,.019), GLOVE))
    return section(pieces, 'support_hand' if support else 'trigger_hand', root, palm)

def rifle(style, root):
    ak, awp = style == 'ak', style == 'awp'
    tint = TAN if awp else GUN
    body = [
        block('Upper receiver', (0,0,.018), (.15,.40,.12), tint, .018),
        block('Lower receiver', (0,-.014,-.064), (.12,.31,.095), tint, .014),
        tube('Buffer tube', (0,-.33,.005), .043,.26),
        block('Stock cheek rest', (0,-.385,.006), (.117,.245,.104), BLACK, .018, POLYMER),
        block('Butt plate', (0,-.525,-.035), (.14,.038,.215), BLACK,.012,POLYMER),
        block('Pistol grip', (0,-.105,-.19), (.079,.096,.235), BLACK,.016,POLYMER),
        block('Trigger guard lower', (0,.008,-.125), (.038,.129,.025), EDGE,.006),
        block('Trigger guard front', (0,.074,-.09), (.038,.028,.085), EDGE,.006),
        block('Trigger', (0,-.009,-.104), (.016,.022,.07), BLACK,.003),
        block('Ejection port', (.078,.025,.031), (.01,.13,.052), BLACK,.002),
        block('Port lower lip', (.086,.025,.002), (.019,.14,.012), EDGE,.003),
        block('Selector plate', (.068,-.095,-.049), (.013,.046,.029), EDGE,.003),
    ]
    fore_colour = (.31,.11,.038) if ak else tint
    body += [block('Handguard', (0,.405,.018), (.116,.39,.103), fore_colour,.016,POLYMER if ak else METAL)]
    length = 1.22 if awp else 1.04
    body += [tube('Free floated barrel', (0,(.58+length-.04)/2,.023), .019 if not awp else .026, length-.04-.58),
             tube('Muzzle device', (0,length-.023,.023), .029,.09),
             block('Gas block', (0,.73,.039), (.048,.073,.071), BLACK,.005)]
    # Top rail teeth, handguard vents and receiver pins catch highlights at FP distance.
    for y in [i*.032-.155 for i in range(24 if not ak else 11)]:
        body.append(block('Picatinny tooth', (0,y,.089), (.069,.017,.020), EDGE,.003))
    for side in [-1,1]:
        for y in [.29,.35,.41,.47,.53]:
            body.append(block('Handguard vent', (side*.059,y,.025), (.008,.041,.031), BLACK,.002))
        for y in [-.12,.10]:
            body.append(tube('Receiver pin', (side*.078,y,-.026), .012,.008, EDGE, 'X'))
        body.append(block('Stock latch', (side*.06,-.36,-.065), (.022,.11,.029), EDGE,.004))
    magazine = []
    if ak:
        for i in range(5):
            z = -.10 - i*.068
            y = .083 + .012*i*i
            part = block('Curved magazine segment', (0,y,z), (.074,.118,.085), BLACK,.009)
            part.rotation_euler.x = -.1*i
            magazine.append(part)
        for side in [-1,1]:
            magazine.append(block('Magazine reinforcing rib', (side*.039,.13,-.25), (.01,.09,.20), EDGE,.002))
    else:
        magazine.append(block('Box magazine', (0,.049,-.222), (.077,.14,.265 if not awp else .13), BLACK,.013))
        for side in [-1,1]:
            for y in [.015,.055,.095]:
                magazine.append(block('Magazine rib', (side*.04,y,-.22), (.009,.013,.18 if not awp else .07), EDGE,.002))
    if awp:
        for y in [-.055,.20]:
            body += [block('Scope foot', (0,y,.117), (.07,.052,.06), BLACK,.005),
                     tube('Scope mounting ring', (0,y,.176), .056,.043,BLACK)]
        body += [tube('Scope body', (0,.07,.176), .044,.40),
                 tube('Objective bell', (0,.313,.176), .067,.12),
                 tube('Eyepiece', (0,-.163,.176), .056,.10),
                 tube('Objective glass', (0,.376,.176), .058,.007, (.06,.16,.19), mat=LENS),
                 tube('Rear glass', (0,-.216,.176), .046,.007, (.065,.17,.20), mat=LENS),
                 tube('Elevation turret', (0,.04,.239), .031,.055, EDGE, 'Z'),
                 tube('Windage turret', (.060,.04,.176), .026,.048, EDGE, 'X')]
        bolt = [tube('Bolt handle', (.105,-.08,.015), .012,.16, EDGE, 'X'),
                oval('Bolt knob', (.191,-.08,.015), (.027,.027,.027), BLACK)]
    else:
        # Supported open rear sight and narrow front post, not disconnected pegs.
        for y in [-.145,.77]:
            body.append(block('Sight base', (0,y,.073), (.073,.052,.056), BLACK,.006))
            for side in [-1,1]:
                body.append(block('Sight ear', (side*.027,y,.124), (.015,.023,.057), EDGE,.004))
        body.append(block('Front sight post', (0,.77,.116), (.009,.016,.041), BLACK,.002))
        bolt = [block('Bolt carrier', (.086,.017,.030), (.017,.103,.035), STEEL,.003)]
    section(body,'weapon_body',root)
    section(magazine,'magazine',root,(0,.07,-.22))
    section(bolt,'bolt',root,(0,-.08,.025))
    return length

def pistol(root):
    body = [block('Pistol frame', (0,.069,-.044), (.112,.27,.095), GUN,.014),
            block('Grip', (0,-.047,-.193), (.103,.114,.247), BLACK,.016,POLYMER),
            block('Trigger guard base', (0,.069,-.137), (.045,.155,.025), GUN,.007),
            block('Trigger guard nose', (0,.141,-.094), (.045,.026,.103), GUN,.006),
            block('Trigger', (0,.062,-.091), (.024,.022,.065), BLACK,.004)]
    slide = [block('Heavy slide', (0,.128,.034), (.125,.41,.108), STEEL,.015),
             tube('Barrel crown', (0,.343,.025), .027,.035, BLACK),
             block('Front sight', (0,.29,.105), (.023,.031,.036), BLACK,.003),
             block('Rear sight base', (0,-.067,.097), (.09,.04,.027), BLACK,.004)]
    for side in [-1,1]:
        slide.append(block('Rear sight ear', (side*.029,-.067,.117), (.025,.025,.037), BLACK,.004))
        for y in [-.048,-.024,0,.024]:
            slide.append(block('Slide serration', (side*.064,y,.038), (.009,.009,.065), EDGE,.002))
        body.append(block('Grip panel', (side*.055,-.047,-.192), (.016,.080,.185), EDGE,.009,POLYMER))
        for z in [-.12,-.25]:
            body.append(tube('Grip screw', (side*.064,-.047,z), .012,.005, STEEL, 'X'))
    section(body,'weapon_body',root)
    section(slide,'bolt',root,(0,.128,.034))
    section([block('Pistol magazine', (0,-.047,-.21), (.071,.080,.25), GUN,.008),
             block('Magazine floor plate', (0,-.047,-.337), (.118,.122,.024), BLACK,.006)],'magazine',root,(0,-.047,-.21))
    return .36

def export_weapon(style):
    root = empty('view_' + style)
    muzzle = pistol(root) if style == 'deagle' else rifle(style,root)
    hand(root,1,False,style=='deagle')
    hand(root,-1,True,style=='deagle')
    empty('muzzle', (0,muzzle,.023), root)
    bpy.ops.object.select_all(action='DESELECT')
    root.select_set(True)
    for obj in root.children_recursive: obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(kit.OUT / ('view_'+style+'.glb')), export_format='GLB',
                              use_selection=True, export_animations=False, export_cameras=False,
                              export_lights=False, export_vertex_color='MATERIAL')
    return root

def main():
    bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
    models = []
    for i, style in enumerate(['m4','ak','awp','deagle']):
        root = export_weapon(style)
        root.location = ((i%2)*1.55-.78, 0, (1-i//2)*.82+.60)
        models.append(root)
    bpy.ops.object.camera_add(location=(3.4,-5.8,3.2))
    camera=bpy.context.object
    camera.rotation_euler=(Vector((0,.22,1.02))-camera.location).to_track_quat('-Z','Y').to_euler()
    camera.data.type='ORTHO'; camera.data.ortho_scale=3.2
    scene=bpy.context.scene; scene.camera=camera
    for location,power in [((1,-3,5),650),((-3,0,4),500),((0,4,5),650)]:
        bpy.ops.object.light_add(type='AREA',location=location)
        light=bpy.context.object; light.data.energy=power; light.data.size=4
        light.rotation_euler=(Vector((0,0,1))-light.location).to_track_quat('-Z','Y').to_euler()
    scene.render.engine='CYCLES'; scene.cycles.device='CPU'; scene.cycles.samples=12
    scene.world.color=(.22,.22,.22)
    scene.render.resolution_x=1100; scene.render.resolution_y=850; scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG'
    scene.render.filepath=str(ROOT/'artifacts'/'weapon-preview.png')
    bpy.ops.render.render(write_still=True)

if __name__ == '__main__': main()
