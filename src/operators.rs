//! Blender-authored, four-draw-call operators with named hip pivots.
use super::*;
use bevy::world_serialization::WorldInstanceReady;

#[derive(Component)]
pub struct BotMuzzle(usize);

pub fn animate_muzzles(sim: Res<Simulation>, mut muzzles: Query<(&BotMuzzle, &mut Visibility)>) {
    for (bot, mut visibility) in &mut muzzles {
        *visibility = if sim.0.bots[bot.0].health > 0. && sim.0.bots[bot.0].flash > 0. {
            Visibility::Visible
        } else {
            Visibility::Hidden
        };
    }
}

pub fn spawn(
    commands: &mut Commands,
    assets: &AssetServer,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
) {
    let flash_mesh = meshes.add(Sphere::new(0.045));
    let flash_mat = materials.add(StandardMaterial {
        base_color: Color::srgb(1., 0.75, 0.3),
        emissive: LinearRgba::new(6., 2., 0.2, 1.),
        unlit: true,
        ..default()
    });
    let ct = assets.load(GltfAssetLabel::Scene(0).from_asset("models/ct_operator.glb"));
    let t = assets.load(GltfAssetLabel::Scene(0).from_asset("models/t_operator.glb"));
    for (i, p) in rules::CT_SPAWNS
        .iter()
        .chain(rules::T_SPAWNS.iter())
        .enumerate()
    {
        commands
            .spawn((
                BotVisual(i),
                WorldAssetRoot(if i < 4 { ct.clone() } else { t.clone() }),
                Transform::from_xyz(p.x, 1.05, p.z),
            ))
            .with_children(|root| {
                root.spawn((
                    BotMuzzle(i),
                    Mesh3d(flash_mesh.clone()),
                    MeshMaterial3d(flash_mat.clone()),
                    Transform::from_xyz(0.09, 0.30, -0.875),
                    Visibility::Hidden,
                    NotShadowCaster,
                ));
            })
            .observe(bind_legs);
    }
}

fn bind_legs(
    ready: On<WorldInstanceReady>,
    roots: Query<&BotVisual>,
    children: Query<&Children>,
    names: Query<&Name>,
    mut commands: Commands,
) {
    let Ok(bot) = roots.get(ready.entity) else {
        return;
    };
    for child in children.iter_descendants(ready.entity) {
        let Ok(name) = names.get(child) else {
            continue;
        };
        // Blender suffixes names when exporting the second team from one scene.
        let base = name.as_str().split('.').next().unwrap_or("");
        if base == "leg_l" || base == "leg_r" {
            commands.entity(child).insert(Limb {
                bot: bot.0,
                side: if base == "leg_l" { -1. } else { 1. },
            });
        }
    }
}
