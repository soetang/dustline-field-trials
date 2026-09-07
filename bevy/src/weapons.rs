//! Original first-person models, loaded on demand with a primitive fallback.
use super::*;
use bevy::world_serialization::WorldInstanceReady;

#[derive(Component)]
pub struct LegacyWeapon;

#[derive(Component)]
pub struct Model {
    slot: usize,
    ready: bool,
}

#[derive(Resource)]
pub struct FlashAssets {
    pub mesh: Handle<Mesh>,
    pub material: Handle<StandardMaterial>,
}

#[derive(Clone, Copy)]
enum Part {
    Magazine,
    Bolt,
    SupportHand,
}

#[derive(Component)]
pub struct MovingPart {
    slot: usize,
    kind: Part,
    rest: Transform,
}

const FILES: [&str; 4] = [
    "models/view_m4.glb",
    "models/view_ak.glb",
    "models/view_awp.glb",
    "models/view_deagle.glb",
];

pub fn select(
    mut commands: Commands,
    assets: Res<AssetServer>,
    game: Res<Simulation>,
    mut session: ResMut<Session>,
    mount: Single<Entity, With<ViewWeapon>>,
    mut models: Query<(&Model, &mut Visibility), Without<LegacyWeapon>>,
    mut fallback: Query<&mut Visibility, With<LegacyWeapon>>,
) {
    let slot = game.0.weapon.slot();
    let mut requested = false;
    session.view_model_ready = false;
    for (model, mut visibility) in &mut models {
        let selected = model.slot == slot;
        requested |= selected;
        let shown = selected && model.ready;
        session.view_model_ready |= shown;
        *visibility = if shown {
            Visibility::Inherited
        } else {
            Visibility::Hidden
        };
    }
    for mut visibility in &mut fallback {
        *visibility = if session.view_model_ready {
            Visibility::Hidden
        } else {
            Visibility::Inherited
        };
    }
    if !requested {
        commands
            .spawn((
                Model { slot, ready: false },
                WorldAssetRoot(assets.load(GltfAssetLabel::Scene(0).from_asset(FILES[slot]))),
                Transform::default(),
                Visibility::Hidden,
                ChildOf(*mount),
            ))
            .observe(bind);
    }
}

fn bind(
    ready: On<WorldInstanceReady>,
    mut models: Query<&mut Model>,
    children: Query<&Children>,
    nodes: Query<(&Name, &Transform)>,
    flash: Res<FlashAssets>,
    mut commands: Commands,
) {
    let Ok(mut model) = models.get_mut(ready.entity) else {
        return;
    };
    for child in children.iter_descendants(ready.entity) {
        // Render layers are not inherited: every imported mesh must be isolated
        // from the world camera, and none should cast a first-person shadow.
        commands
            .entity(child)
            .insert((RenderLayers::layer(VIEW_MODEL_LAYER), NotShadowCaster));
        let Ok((name, transform)) = nodes.get(child) else {
            continue;
        };
        let base = name.as_str().split('.').next().unwrap_or("");
        let part = match base {
            "magazine" => Some(Part::Magazine),
            "bolt" => Some(Part::Bolt),
            "support_hand" => Some(Part::SupportHand),
            _ => None,
        };
        if let Some(kind) = part {
            commands.entity(child).insert(MovingPart {
                slot: model.slot,
                kind,
                rest: *transform,
            });
        }
        if base == "muzzle" {
            commands.entity(child).with_children(|node| {
                node.spawn((
                    MuzzleFlash,
                    Mesh3d(flash.mesh.clone()),
                    MeshMaterial3d(flash.material.clone()),
                    Transform::default(),
                    RenderLayers::layer(VIEW_MODEL_LAYER),
                    NotShadowCaster,
                    Visibility::Hidden,
                ));
            });
        }
    }
    model.ready = true;
}

pub fn animate(
    game: Res<Simulation>,
    session: Res<Session>,
    mut parts: Query<(&MovingPart, &mut Transform)>,
) {
    if session.started && !session.active {
        return;
    }
    let reload = if game.0.reload > 0. {
        1. - game.0.reload / game.0.weapon.spec().reload
    } else {
        0.
    };
    let remove = ((reload - 0.10) / 0.72).clamp(0., 1.);
    let dip = (remove * PI).sin();
    let bolt = (session.flash / 0.055).clamp(0., 1.);
    for (part, mut transform) in &mut parts {
        if part.slot != game.0.weapon.slot() {
            continue;
        }
        *transform = part.rest;
        match part.kind {
            Part::Magazine => {
                transform.translation.y -= dip * 0.32;
                transform.rotation *= Quat::from_rotation_x(dip * 0.18);
            }
            Part::SupportHand => {
                transform.translation += Vec3::new(-dip * 0.06, -dip * 0.24, dip * 0.15);
                transform.rotation *= Quat::from_rotation_z(dip * -0.25);
            }
            Part::Bolt => {
                transform.translation.z += bolt * if part.slot == 3 { 0.10 } else { 0.075 }
            }
        }
    }
}
