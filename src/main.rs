use bevy::{
    asset::AssetMetaCheck,
    camera::visibility::RenderLayers,
    core_pipeline::tonemapping::Tonemapping,
    input::mouse::AccumulatedMouseMotion,
    light::{CascadeShadowConfigBuilder, DirectionalLightShadowMap, NotShadowCaster},
    prelude::*,
    window::{CursorOptions, PresentMode},
};
use std::f32::consts::{FRAC_PI_2, PI};
mod arena;
mod environment;
mod gameplay;
mod operators;
mod rules;
#[cfg(not(target_arch = "wasm32"))]
use bevy::window::CursorGrabMode;
use gameplay::*;
use rules::{BombState, Game, Phase, Team, Weapon};
const MAP_W: usize = rules::W;
const MAP_H: usize = rules::H;
const WORLD_LAYER: usize = 0;
const VIEW_MODEL_LAYER: usize = 1;
const PLAYER_HEIGHT: f32 = 1.62;
fn layout_position(x: f32, y: f32, z: f32) -> Vec3 {
    let p = rules::Point::layout(x, z);
    Vec3::new(p.x, y, p.z)
}
#[derive(Component)]
struct Player;
#[derive(Component)]
struct WorldCamera;
#[derive(Component)]
struct ViewWeapon {
    rest: Vec3,
}
#[derive(Component)]
struct MuzzleFlash;
#[derive(Component)]
struct WeaponPart(u8);
#[derive(Component)]
struct BotVisual(usize);
#[derive(Component)]
struct Limb {
    bot: usize,
    side: f32,
}
#[derive(Component)]
struct BombVisual;
#[derive(Component)]
struct Effect {
    life: f32,
    velocity: Vec3,
    gravity: f32,
}
#[cfg(not(target_arch = "wasm32"))]
#[derive(Component)]
struct NativeHud;
#[derive(Resource, Default)]
struct Simulation(Game);
#[derive(Resource, Default)]
struct Controls {
    forward: f32,
    strafe: f32,
    look: Vec2,
    fire: bool,
    fire_pressed: bool,
    aim: bool,
    walk: bool,
    crouch: bool,
    reload: bool,
    defuse: bool,
}
#[derive(Resource)]
struct Session {
    started: bool,
    active: bool,
    low_quality: bool,
    shop: bool,
    aiming: bool,
    moving: bool,
    crouch: bool,
    recoil: f32,
    flash: f32,
    stride: f32,
    sensitivity: f32,
    round: u32,
    hud_timer: f32,
    spectator: usize,
}
impl Default for Session {
    fn default() -> Self {
        Self {
            started: false,
            active: false,
            low_quality: false,
            shop: false,
            aiming: false,
            moving: false,
            crouch: false,
            recoil: 0.,
            flash: 0.,
            stride: 0.,
            sensitivity: 1.,
            round: 1,
            hud_timer: 0.,
            spectator: 0,
        }
    }
}
fn main() {
    install_panic_hook();
    App::new()
        .insert_resource(ClearColor(Color::srgb(0.42, 0.61, 0.74)))
        .insert_resource(GlobalAmbientLight {
            color: Color::srgb(0.72, 0.79, 0.84),
            brightness: 550.0,
            ..default()
        })
        .insert_resource(DirectionalLightShadowMap { size: 1024 })
        .init_resource::<Simulation>()
        .init_resource::<Controls>()
        .init_resource::<Session>()
        .add_plugins(
            DefaultPlugins
                .set(AssetPlugin {
                    meta_check: AssetMetaCheck::Never,
                    ..default()
                })
                .set(WindowPlugin {
                    primary_window: Some(Window {
                        title: "Dustline: Field Trials".into(),
                        canvas: Some("#bevy-canvas".into()),
                        fit_canvas_to_parent: true,
                        prevent_default_event_handling: true,
                        present_mode: PresentMode::AutoVsync,
                        ..default()
                    }),
                    ..default()
                }),
        )
        .add_systems(Startup, setup)
        .add_systems(
            Update,
            (
                read_controls,
                render_quality,
                simulate,
                player_controller,
                weapon_management,
                fire_weapon,
                animate_scene,
                operators::animate_muzzles,
                sync_hud,
            )
                .chain(),
        )
        .run();
}

fn setup(
    mut commands: Commands,
    game: Res<Simulation>,
    assets: Res<AssetServer>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
) {
    let map = &game.0.map;
    let sandstone = [
        materials.add(arena::concrete(
            &assets,
            "concrete_wall_001",
            Color::srgb(0.94, 0.88, 0.75),
        )),
        materials.add(arena::concrete(
            &assets,
            "concrete_wall_001",
            Color::srgb(0.72, 0.79, 0.75),
        )),
        materials.add(arena::concrete(
            &assets,
            "concrete_wall_001",
            Color::srgb(0.86, 0.73, 0.54),
        )),
    ];
    let stone = materials.add(StandardMaterial {
        base_color: Color::srgb(0.42, 0.36, 0.29),
        perceptual_roughness: 0.98,
        ..default()
    });
    let wood = materials.add(StandardMaterial {
        base_color: Color::srgb(0.36, 0.2, 0.08),
        perceptual_roughness: 0.82,
        ..default()
    });
    let wood_edge = materials.add(StandardMaterial {
        base_color: Color::srgb(0.2, 0.1, 0.035),
        perceptual_roughness: 0.74,
        metallic: 0.05,
        ..default()
    });
    let ground = materials.add(arena::concrete(
        &assets,
        "concrete_floor",
        Color::srgb(0.82, 0.79, 0.72),
    ));
    let trim = materials.add(StandardMaterial {
        base_color: Color::srgb(0.47, 0.34, 0.21),
        perceptual_roughness: 0.9,
        ..default()
    });
    let metal = materials.add(StandardMaterial {
        base_color: Color::srgb(0.16, 0.2, 0.21),
        metallic: 0.72,
        perceptual_roughness: 0.34,
        ..default()
    });

    let floor = arena::ground_mesh(map);
    commands.spawn((
        Mesh3d(meshes.add(floor)),
        MeshMaterial3d(ground),
        Transform::default(),
    ));

    // Merge the static architecture into seven meshes instead of hundreds of draw calls.
    let mut geometry: Vec<Option<Mesh>> = (0..7).map(|_| None).collect();
    let mut add_block = |group: usize, size: Vec3, position: Vec3| {
        let mesh = Mesh::from(Cuboid::from_size(size))
            .transformed_by(Transform::from_translation(position));
        if let Some(combined) = &mut geometry[group] {
            combined
                .merge(&mesh)
                .expect("Cuboids have matching vertex attributes");
        } else {
            geometry[group] = Some(mesh);
        }
    };
    for z in 0..MAP_H {
        for x in 0..MAP_W {
            let tile = map.tiles[z][x];
            if tile == 1
                && x > 0
                && z > 0
                && x < MAP_W - 1
                && z < MAP_H - 1
                && [(x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1)]
                    .iter()
                    .all(|(nx, nz)| map.tiles[*nz][*nx] == 1)
            {
                continue;
            }
            let Some((min, max)) = map.tile_bounds(x, z) else {
                continue;
            };
            let p = Vec3::new(x as f32 + 0.5, min[1], z as f32 + 0.5);
            let height = max[1] - min[1];
            match tile {
                1 => {
                    add_block(
                        (x / 8 + z / 8) % 3,
                        Vec3::new(1., height, 1.),
                        p + Vec3::Y * (height / 2.),
                    );
                    add_block(
                        3,
                        Vec3::new(1.06, 0.12, 1.06),
                        p + Vec3::Y * (height + 0.04),
                    );
                }
                2 => add_block(4, Vec3::new(0.94, 1.65, 0.94), p + Vec3::Y * 0.825),
                3 => {
                    add_block(5, Vec3::new(0.86, 1.18, 0.86), p + Vec3::Y * 0.59);
                    add_block(
                        6,
                        Vec3::new(0.94, 0.09, 0.06),
                        p + Vec3::new(0., 0.59, -0.445),
                    );
                    add_block(6, Vec3::new(0.06, 1.08, 0.94), p + Vec3::Y * 0.59);
                }
                _ => {}
            }
        }
    }
    let palette = [
        sandstone[0].clone(),
        sandstone[1].clone(),
        sandstone[2].clone(),
        trim.clone(),
        stone,
        wood,
        wood_edge,
    ];
    for (mesh, material) in geometry.into_iter().zip(palette) {
        if let Some(mut mesh) = mesh {
            arena::world_uv(&mut mesh, 1.5);
            commands.spawn((
                Mesh3d(meshes.add(mesh)),
                MeshMaterial3d(material),
                Transform::default(),
            ));
        }
    }

    spawn_environment_details(
        &mut commands,
        &mut meshes,
        &mut materials,
        map,
        metal.clone(),
        trim,
    );
    spawn_lighting(&mut commands);
    spawn_player(&mut commands, &mut meshes, &mut materials, metal);
    operators::spawn(&mut commands, &assets, &mut meshes, &mut materials);
    environment::spawn(&mut commands, &mut meshes, &mut materials);
    spawn_landmarks(&mut commands, &mut meshes, &mut materials, map);
    #[cfg(not(target_arch = "wasm32"))]
    commands.spawn((
        NativeHud,
        Text::new("DUSTLINE: FIELD TRIALS\nClick or Enter to deploy"),
        TextFont {
            font_size: 22.0,
            ..default()
        },
        Node {
            position_type: PositionType::Absolute,
            top: px(20),
            left: px(24),
            ..default()
        },
    ));
}

fn spawn_environment_details(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    map: &rules::Map,
    metal: Handle<StandardMaterial>,
    trim: Handle<StandardMaterial>,
) {
    let site_a = materials.add(StandardMaterial {
        base_color: Color::srgba(0.65, 0.12, 0.055, 0.72),
        emissive: LinearRgba::new(0.18, 0.025, 0.005, 1.0),
        perceptual_roughness: 0.86,
        ..default()
    });
    let site_mesh = meshes.add(Cylinder::new(2.05, 0.035));
    for site in rules::SITES {
        commands.spawn((
            Mesh3d(site_mesh.clone()),
            MeshMaterial3d(site_a.clone()),
            Transform::from_xyz(site.x, map.elevation(site.x, site.z) + 0.025, site.z),
        ));
    }

    let barrel_mesh = meshes.add(Cylinder::new(0.26, 0.78));
    for (i, mut position) in [
        layout_position(6.4, 0.39, 6.1),
        layout_position(6.95, 0.39, 6.15),
        layout_position(22.2, 0.39, 7.1),
        layout_position(27.2, 0.39, 17.6),
        layout_position(13.7, 0.39, 14.2),
    ]
    .into_iter()
    .enumerate()
    {
        position.y += map.elevation(position.x, position.z);
        let rust = materials.add(StandardMaterial {
            base_color: if i % 2 == 0 {
                Color::srgb(0.11, 0.22, 0.24)
            } else {
                Color::srgb(0.3, 0.18, 0.08)
            },
            metallic: 0.62,
            perceptual_roughness: 0.53,
            ..default()
        });
        commands.spawn((
            Mesh3d(barrel_mesh.clone()),
            MeshMaterial3d(rust),
            Transform::from_translation(position),
        ));
    }

    // Structural beams and overhead lintels make the corridors read as built spaces.
    use rules::scenery;
    let pillar = meshes.add(Cuboid::from_size(Vec3::from_array(scenery::PILLAR_SIZE)));
    let lintel = meshes.add(Cuboid::from_size(Vec3::from_array(scenery::LINTEL_SIZE)));
    for position in scenery::CT_PILLARS {
        commands.spawn((
            Mesh3d(pillar.clone()),
            MeshMaterial3d(trim.clone()),
            Transform::from_translation(Vec3::from_array(position)),
        ));
    }
    commands.spawn((
        Mesh3d(lintel),
        MeshMaterial3d(trim),
        Transform::from_translation(Vec3::from_array(scenery::CT_LINTEL)),
    ));

    let lamp_mesh = meshes.add(Cuboid::from_size(Vec3::from_array(scenery::LAMP_SIZE)));
    let glass_mesh = meshes.add(Cuboid::new(0.14, 0.22, 0.014));
    let glass = materials.add(StandardMaterial {
        base_color: Color::srgb(1., 0.76, 0.38),
        emissive: LinearRgba::new(2.8, 1.4, 0.4, 1.),
        ..default()
    });
    // Mount the CT lamps on the front of the lintel's pillars. The old third
    // fixture at (44.8, 2, 13) was an unsupported dark box over walkable ground;
    // it now belongs to the north wall of B site.
    for (position, facing) in scenery::LAMPS {
        let position = Vec3::from_array(position);
        commands.spawn((
            Mesh3d(lamp_mesh.clone()),
            MeshMaterial3d(metal.clone()),
            Transform::from_translation(position),
        ));
        commands.spawn((
            Mesh3d(glass_mesh.clone()),
            MeshMaterial3d(glass.clone()),
            Transform::from_translation(position + Vec3::Z * facing * 0.076),
        ));
        commands.spawn((
            PointLight {
                color: Color::srgb(1.0, 0.64, 0.3),
                intensity: 750.0,
                range: 6.0,
                shadow_maps_enabled: false,
                ..default()
            },
            Transform::from_translation(position + Vec3::new(0.0, -0.1, facing * 0.2)),
        ));
    }
}

fn spawn_lighting(commands: &mut Commands) {
    commands.spawn((
        DirectionalLight {
            color: Color::srgb(1.0, 0.82, 0.61),
            illuminance: 18_000.0,
            shadow_maps_enabled: true,
            ..default()
        },
        Transform::from_rotation(Quat::from_euler(EulerRot::XYZ, -1.08, -0.62, -0.18)),
        CascadeShadowConfigBuilder {
            num_cascades: if cfg!(target_arch = "wasm32") { 1 } else { 2 },
            maximum_distance: 65.0,
            ..default()
        }
        .build(),
        RenderLayers::from_layers(&[WORLD_LAYER, VIEW_MODEL_LAYER]),
    ));
}

fn spawn_player(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    metal: Handle<StandardMaterial>,
) {
    let glove = materials.add(StandardMaterial {
        base_color: Color::srgb(0.07, 0.11, 0.12),
        perceptual_roughness: 0.76,
        ..default()
    });
    let gun_dark = materials.add(StandardMaterial {
        base_color: Color::srgb(0.1, 0.13, 0.14),
        metallic: 0.78,
        perceptual_roughness: 0.26,
        ..default()
    });
    let flash = materials.add(StandardMaterial {
        base_color: Color::srgb(1.0, 0.55, 0.08),
        emissive: LinearRgba::new(14.0, 5.0, 0.2, 1.0),
        ..default()
    });

    let arm_mesh = meshes.add(Cuboid::new(0.13, 0.13, 0.62));
    let receiver_mesh = meshes.add(Cuboid::new(0.19, 0.15, 0.46));
    let handguard_mesh = meshes.add(Cuboid::new(0.13, 0.11, 0.42));
    let barrel_mesh = meshes.add(Cylinder::new(0.018, 0.58));
    // Both sight posts must reach the receiver/barrel beneath them; short
    // disconnected posts read as little dark objects floating in the view.
    let sight_mesh = meshes.add(Cuboid::new(0.035, 0.10, 0.035));
    let muzzle_mesh = meshes.add(Sphere::new(0.065));

    commands
        .spawn((
            Player,
            Transform::from_xyz(rules::PLAYER_SPAWN.x, PLAYER_HEIGHT, rules::PLAYER_SPAWN.z)
                .with_rotation(Quat::from_rotation_y(PI)),
            Visibility::default(),
        ))
        .with_children(|player| {
            player.spawn((
                WorldCamera,
                Camera3d::default(),
                Msaa::Off,
                Projection::from(PerspectiveProjection {
                    fov: 78.0_f32.to_radians(),
                    ..default()
                }),
                Tonemapping::TonyMcMapface,
                DistanceFog {
                    color: Color::srgba(0.58, 0.65, 0.66, 1.0),
                    directional_light_color: Color::srgba(1.0, 0.82, 0.62, 0.42),
                    directional_light_exponent: 22.0,
                    falloff: FogFalloff::Linear {
                        start: 28.0,
                        end: 78.0,
                    },
                },
            ));
            player.spawn((
                Camera3d::default(),
                Msaa::Off,
                Camera {
                    order: 1,
                    clear_color: ClearColorConfig::None,
                    ..default()
                },
                Projection::from(PerspectiveProjection {
                    fov: 68.0_f32.to_radians(),
                    ..default()
                }),
                RenderLayers::layer(VIEW_MODEL_LAYER),
            ));
            player
                .spawn((
                    ViewWeapon {
                        rest: Vec3::new(0.26, -0.30, -0.76),
                    },
                    Transform::from_xyz(0.26, -0.30, -0.76).with_scale(Vec3::splat(0.58)),
                    Visibility::default(),
                ))
                .with_children(|weapon| {
                    let layer = RenderLayers::layer(VIEW_MODEL_LAYER);
                    weapon.spawn((
                        WeaponPart(0),
                        Mesh3d(receiver_mesh),
                        MeshMaterial3d(gun_dark.clone()),
                        Transform::default(),
                        layer.clone(),
                        NotShadowCaster,
                    ));
                    weapon.spawn((
                        WeaponPart(1),
                        Mesh3d(handguard_mesh),
                        MeshMaterial3d(metal),
                        Transform::from_xyz(-0.01, 0.015, -0.41),
                        layer.clone(),
                        NotShadowCaster,
                    ));
                    weapon.spawn((
                        WeaponPart(2),
                        Mesh3d(barrel_mesh),
                        MeshMaterial3d(gun_dark.clone()),
                        Transform::from_xyz(-0.01, 0.01, -0.82)
                            .with_rotation(Quat::from_rotation_x(FRAC_PI_2)),
                        layer.clone(),
                        NotShadowCaster,
                    ));
                    weapon.spawn((
                        WeaponPart(3),
                        Mesh3d(sight_mesh.clone()),
                        MeshMaterial3d(gun_dark.clone()),
                        Transform::from_xyz(-0.01, 0.12, -0.21),
                        layer.clone(),
                        NotShadowCaster,
                    ));
                    weapon.spawn((
                        WeaponPart(4),
                        Mesh3d(sight_mesh),
                        MeshMaterial3d(gun_dark.clone()),
                        Transform::from_xyz(-0.01, 0.075, -1.1),
                        layer.clone(),
                        NotShadowCaster,
                    ));
                    weapon.spawn((
                        Mesh3d(arm_mesh.clone()),
                        MeshMaterial3d(glove.clone()),
                        Transform::from_xyz(0.23, -0.15, 0.24)
                            .with_rotation(Quat::from_rotation_y(-0.25)),
                        layer.clone(),
                        NotShadowCaster,
                    ));
                    weapon.spawn((
                        Mesh3d(arm_mesh),
                        MeshMaterial3d(glove),
                        Transform::from_xyz(-0.2, -0.13, -0.2)
                            .with_rotation(Quat::from_rotation_y(0.36)),
                        layer.clone(),
                        NotShadowCaster,
                    ));
                    for (part, size, position) in [
                        (5, Vec3::new(0.14, 0.23, 0.32), Vec3::new(0.0, -0.02, 0.34)),
                        (6, Vec3::new(0.1, 0.3, 0.16), Vec3::new(0.0, -0.20, -0.04)),
                        (7, Vec3::new(0.095, 0.23, 0.12), Vec3::new(0.0, -0.18, 0.14)),
                        (8, Vec3::new(0.11, 0.12, 0.38), Vec3::new(0.0, 0.19, -0.12)),
                    ] {
                        weapon.spawn((
                            WeaponPart(part),
                            Mesh3d(meshes.add(Cuboid::from_size(size))),
                            MeshMaterial3d(gun_dark.clone()),
                            Transform::from_translation(position),
                            layer.clone(),
                            NotShadowCaster,
                        ));
                    }
                    weapon.spawn((
                        MuzzleFlash,
                        Mesh3d(muzzle_mesh),
                        MeshMaterial3d(flash),
                        Transform::from_xyz(-0.01, 0.01, -1.12),
                        layer,
                        NotShadowCaster,
                        Visibility::Hidden,
                    ));
                });
        });
}
