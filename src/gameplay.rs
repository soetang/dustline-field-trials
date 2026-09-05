use super::*;

#[cfg(target_arch = "wasm32")]
mod browser {
    use wasm_bindgen::prelude::*;
    #[wasm_bindgen(
        inline_js = "export function input(){return JSON.stringify(window.desertStrike?.input() || {});} export function hud(s){window.desertStrike?.render(JSON.parse(s));} export function report_panic(s){window.desertStrike?.fail(new Error(s));}"
    )]
    extern "C" {
        pub fn input() -> String;
        pub fn hud(state: &str);
        pub fn report_panic(message: &str);
    }
}

pub fn install_panic_hook() {
    #[cfg(target_arch = "wasm32")]
    std::panic::set_hook(Box::new(|info| browser::report_panic(&info.to_string())));
}

pub fn read_controls(
    keys: Res<ButtonInput<KeyCode>>,
    mouse: Res<ButtonInput<MouseButton>>,
    motion: Res<AccumulatedMouseMotion>,
    mut controls: ResMut<Controls>,
    mut cursor: Single<&mut CursorOptions>,
    mut session: ResMut<Session>,
    mut sim: ResMut<Simulation>,
) {
    #[cfg(target_arch = "wasm32")]
    {
        let input: serde_json::Value = serde_json::from_str(&browser::input()).unwrap_or_default();
        session.active = input["active"].as_bool().unwrap_or(false);
        session.shop = input["shop"].as_bool().unwrap_or(false);
        session.low_quality = input["quality"].as_str() == Some("low");
        session.sensitivity = input["sensitivity"].as_f64().unwrap_or(1.) as f32;
        let held = |key: &str| input["held"][key].as_bool().unwrap_or(false);
        controls.forward = u8::from(held("KeyW")) as f32 - u8::from(held("KeyS")) as f32;
        controls.strafe = u8::from(held("KeyD")) as f32 - u8::from(held("KeyA")) as f32;
        controls.fire = held("fire");
        controls.fire_pressed = input["firePressed"].as_bool().unwrap_or(false);
        controls.aim = held("aim");
        controls.walk = held("ShiftLeft") || held("ShiftRight");
        controls.crouch = held("ControlLeft");
        controls.defuse = held("KeyE");
        controls.reload = input["reloadPressed"].as_bool().unwrap_or(false);
        controls.look = Vec2::new(
            input["lookX"].as_f64().unwrap_or(0.) as f32,
            input["lookY"].as_f64().unwrap_or(0.) as f32,
        );
        if let Some(commands) = input["commands"].as_array() {
            for command in commands.iter().filter_map(|v| v.as_str()) {
                match command {
                    "start" => {
                        if !session.started {
                            sim.0 = Game::seeded(input["seed"].as_u64().unwrap_or(1) as u32);
                        }
                        session.started = true;
                    }
                    "restart" => {
                        sim.0 = Game::seeded(input["seed"].as_u64().unwrap_or(1) as u32);
                        session.round = 0;
                        session.started = true;
                    }
                    "buy0" => {
                        sim.0.buy(Weapon::M4);
                    }
                    "buy1" => {
                        sim.0.buy(Weapon::Ak);
                    }
                    "buy2" => {
                        sim.0.buy(Weapon::Awp);
                    }
                    "buy3" => {
                        sim.0.buy(Weapon::Deagle);
                    }
                    "spectate" if sim.0.health <= 0. => {
                        session.spectator = (session.spectator + 1) % 4;
                    }
                    _ => {}
                }
            }
        }
        // Pointer capture is managed by the accessible browser overlays.
        let _ = (&keys, &mouse, &mut cursor, &motion);
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        controls.forward = u8::from(keys.pressed(KeyCode::KeyW)) as f32
            - u8::from(keys.pressed(KeyCode::KeyS)) as f32;
        controls.strafe = u8::from(keys.pressed(KeyCode::KeyD)) as f32
            - u8::from(keys.pressed(KeyCode::KeyA)) as f32;
        controls.fire = mouse.pressed(MouseButton::Left);
        controls.fire_pressed = mouse.just_pressed(MouseButton::Left);
        controls.aim = mouse.pressed(MouseButton::Right);
        controls.walk = keys.pressed(KeyCode::ShiftLeft);
        controls.crouch = keys.pressed(KeyCode::ControlLeft);
        controls.defuse = keys.pressed(KeyCode::KeyE);
        controls.reload = keys.just_pressed(KeyCode::KeyR);
        controls.look = motion.delta;
        if keys.just_pressed(KeyCode::Enter)
            || (!session.active && mouse.just_pressed(MouseButton::Left))
        {
            if sim.0.phase == Phase::Finished {
                sim.0 = Game::default();
                session.round = 0;
            }
            session.started = true;
            session.active = true;
            cursor.grab_mode = CursorGrabMode::Locked;
            cursor.visible = false;
        }
        if keys.just_pressed(KeyCode::Escape) {
            session.active = false;
            cursor.grab_mode = CursorGrabMode::None;
            cursor.visible = true;
        }
        if keys.just_pressed(KeyCode::KeyB) && session.active {
            session.shop = !session.shop;
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    if session.active && session.shop {
        for (key, weapon) in [
            (KeyCode::Digit1, Weapon::M4),
            (KeyCode::Digit2, Weapon::Ak),
            (KeyCode::Digit3, Weapon::Awp),
            (KeyCode::Digit4, Weapon::Deagle),
        ] {
            if keys.just_pressed(key) {
                sim.0.buy(weapon);
            }
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    if keys.just_pressed(KeyCode::KeyC) && sim.0.health <= 0. {
        session.spectator = (session.spectator + 1) % 4;
    }
}

pub fn render_quality(session: Res<Session>, mut lights: Query<&mut DirectionalLight>) {
    for mut light in &mut lights {
        if light.shadow_maps_enabled == session.low_quality {
            light.shadow_maps_enabled = !session.low_quality;
        }
    }
}

pub fn simulate(
    time: Res<Time>,
    controls: Res<Controls>,
    session: Res<Session>,
    mut sim: ResMut<Simulation>,
) {
    if session.started && session.active {
        // Keep match time and bot movement consistent on slower render frames.
        let mut remaining = time.delta_secs().min(0.25);
        let mut shots = Vec::new();
        while remaining > 0.00001 {
            let step = remaining.min(0.05);
            sim.0.tick(step, controls.defuse && !session.shop);
            shots.append(&mut sim.0.shots);
            remaining -= step;
        }
        sim.0.shots = shots;
    } else {
        sim.0.shots.clear();
    }
}

pub fn player_controller(
    time: Res<Time>,
    controls: Res<Controls>,
    mut session: ResMut<Session>,
    mut sim: ResMut<Simulation>,
    mut player: Single<&mut Transform, With<Player>>,
    mut projection: Single<&mut Projection, With<WorldCamera>>,
) {
    let game = &mut sim.0;
    if game.round != session.round {
        session.round = game.round;
        player.rotation = Quat::from_rotation_y(PI);
        session.recoil = 0.;
        session.shop = false;
    }
    // A pause/screenshot must preserve the actual view, including crouch and
    // scope zoom, rather than standing up or easing the camera behind the menu.
    if session.started && !session.active {
        return;
    }
    session.moving = false;
    session.aiming =
        session.active && !session.shop && controls.aim && game.health > 0. && game.reload <= 0.;
    session.crouch = session.active && !session.shop && controls.crouch;
    if game.health <= 0. {
        if let Some((i, bot)) = (0..4)
            .map(|offset| {
                let i = (session.spectator + offset) % 4;
                (i, &game.bots[i])
            })
            .find(|(_, b)| b.health > 0.)
        {
            session.spectator = i;
            player.translation = Vec3::new(
                bot.pos.x,
                game.map.elevation(bot.pos.x, bot.pos.z) + 1.72,
                bot.pos.z,
            );
            player.rotation = Quat::from_rotation_y(bot.yaw);
        }
    } else {
        if session.active && !session.shop && session.started && game.phase != Phase::Finished {
            let (yaw, pitch, _) = player.rotation.to_euler(EulerRot::YXZ);
            let sensitivity = 0.0022 * session.sensitivity * if session.aiming { 0.45 } else { 1. };
            player.rotation = Quat::from_euler(
                EulerRot::YXZ,
                yaw - controls.look.x * sensitivity,
                (pitch - controls.look.y * sensitivity).clamp(-1.35, 1.35),
                0.,
            );
            if matches!(game.phase, Phase::Buy | Phase::Live) && game.bomb.defuser != Some(9) {
                let forward =
                    Vec3::new(player.forward().x, 0., player.forward().z).normalize_or_zero();
                let right = Vec3::new(player.right().x, 0., player.right().z).normalize_or_zero();
                let direction =
                    (forward * controls.forward + right * controls.strafe).normalize_or_zero();
                session.moving = direction != Vec3::ZERO;
                let speed = if session.crouch {
                    1.25
                } else if controls.walk || session.aiming {
                    1.75
                } else {
                    3.65
                };
                let delta = direction * speed * time.delta_secs().min(0.25);
                game.map.move_by(&mut game.pos, delta.x, delta.z);
                if session.moving {
                    session.stride += time.delta_secs() * speed * 3.5;
                }
            }
        }
        let height = game.map.elevation(game.pos.x, game.pos.z)
            + if session.crouch { 1.13 } else { PLAYER_HEIGHT };
        player.translation = Vec3::new(
            game.pos.x,
            player.translation.y
                + (height - player.translation.y) * (time.delta_secs() * 16.).min(1.),
            game.pos.z,
        );
    }
    if let Projection::Perspective(p) = &mut **projection {
        let fov = if session.aiming {
            if game.weapon == Weapon::Awp { 26. } else { 58. }
        } else {
            78.
        };
        p.fov += (f32::to_radians(fov) - p.fov) * (time.delta_secs() * 14.).min(1.);
    }
}

pub fn weapon_management(
    controls: Res<Controls>,
    session: Res<Session>,
    mut sim: ResMut<Simulation>,
) {
    if session.active && !session.shop && controls.reload {
        sim.0.start_reload();
    }
}

pub fn fire_weapon(
    controls: Res<Controls>,
    player: Single<&Transform, With<Player>>,
    mut session: ResMut<Session>,
    mut sim: ResMut<Simulation>,
) {
    if !session.active || session.shop || !session.started {
        return;
    }
    let firing = if sim.0.weapon.spec().auto {
        controls.fire || controls.fire_pressed
    } else {
        controls.fire_pressed
    };
    if firing {
        let origin = player.translation;
        let direction = *player.forward();
        if sim.0.fire(
            origin.to_array(),
            direction.to_array(),
            session.moving,
            session.aiming,
        ) {
            session.recoil = (session.recoil + 0.55).min(1.6);
            session.flash = 0.055;
        }
    }
}

#[derive(Resource)]
pub struct EffectAssets {
    cube: Handle<Mesh>,
    sphere: Handle<Mesh>,
    tracer: Handle<StandardMaterial>,
    spark: Handle<StandardMaterial>,
    mark: Handle<StandardMaterial>,
}

pub fn animate_scene(
    time: Res<Time>,
    mut commands: Commands,
    sim: Res<Simulation>,
    mut session: ResMut<Session>,
    assets: Res<EffectAssets>,
    mut objects: Query<(
        Entity,
        &mut Transform,
        Option<&BotVisual>,
        Option<&Limb>,
        Option<&ViewWeapon>,
        Option<&WeaponPart>,
        Option<&mut Effect>,
        Option<&BombVisual>,
        Option<&MuzzleFlash>,
        Option<&mut Visibility>,
    )>,
) {
    if session.started && !session.active {
        return;
    }
    let dt = if session.active {
        time.delta_secs().min(0.25)
    } else {
        0.
    };
    let game = &sim.0;
    session.recoil = (session.recoil - dt * 5.).max(0.);
    session.flash = (session.flash - dt).max(0.);
    for (entity, mut transform, bot, limb, weapon, part, effect, bomb, muzzle, visibility) in
        &mut objects
    {
        if let Some(bot) = bot {
            let b = &game.bots[bot.0];
            transform.translation = Vec3::new(
                b.pos.x,
                game.map.elevation(b.pos.x, b.pos.z) + if b.health > 0. { 1.05 } else { 0.22 },
                b.pos.z,
            );
            transform.rotation = Quat::from_euler(
                EulerRot::YXZ,
                b.yaw,
                0.,
                if b.health > 0. { 0. } else { FRAC_PI_2 },
            );
        }
        if let Some(limb) = limb {
            let b = &game.bots[limb.bot];
            transform.rotation = Quat::from_rotation_x(if b.moving && b.health > 0. {
                (time.elapsed_secs() * 9. + limb.bot as f32 * 1.9).sin() * 0.45 * limb.side
            } else {
                0.
            });
        }
        if let Some(weapon) = weapon {
            let reload = if game.reload > 0. {
                (1. - game.reload / game.weapon.spec().reload) * PI
            } else {
                0.
            };
            let bob = if session.moving {
                session.stride.sin() * 0.014
            } else {
                (time.elapsed_secs() * 1.8).sin() * 0.002
            };
            let aimed = if session.aiming {
                Vec3::new(-0.19, 0.07, 0.05)
            } else {
                Vec3::ZERO
            };
            transform.translation = weapon.rest
                + aimed
                + Vec3::new(
                    bob,
                    session.recoil * 0.028 - reload.sin() * 0.18 + bob.abs(),
                    session.recoil * 0.12,
                );
            transform.rotation = Quat::from_euler(
                EulerRot::XYZ,
                -session.recoil * 0.065 - reload.sin() * 0.28,
                0.,
                reload.sin() * -0.65,
            );
        }
        if let Some(part) = part {
            transform.scale = Vec3::ONE;
            if game.weapon == Weapon::Deagle {
                transform.scale = match part.0 {
                    0 => Vec3::new(0.8, 0.85, 0.7),
                    1 | 2 | 4 | 5 | 6 | 8 => Vec3::ZERO,
                    _ => Vec3::ONE,
                };
            } else if part.0 == 8 {
                transform.scale = if game.weapon == Weapon::Awp {
                    Vec3::ONE
                } else {
                    Vec3::ZERO
                };
            } else if game.weapon == Weapon::Awp && part.0 == 2 {
                transform.scale = Vec3::new(1.4, 1.25, 1.4);
            } else if game.weapon == Weapon::Ak && part.0 == 6 {
                transform.rotation = Quat::from_rotation_x(-0.22);
                transform.scale = Vec3::new(1., 1.25, 1.);
            } else if part.0 == 6 {
                transform.rotation = Quat::IDENTITY;
            }
        }
        if let Some(mut effect) = effect {
            effect.life -= dt;
            transform.translation += effect.velocity * dt;
            let gravity = effect.gravity;
            effect.velocity.y -= dt * gravity;
            if effect.life <= 0. {
                commands.entity(entity).despawn();
            }
        }
        if bomb.is_some() {
            transform.translation = Vec3::new(
                game.bomb.pos.x,
                game.map.elevation(game.bomb.pos.x, game.bomb.pos.z) + 0.13,
                game.bomb.pos.z,
            );
        }
        if let Some(mut visibility) = visibility {
            if muzzle.is_some() {
                *visibility = if session.flash > 0. {
                    Visibility::Visible
                } else {
                    Visibility::Hidden
                };
            }
            if weapon.is_some() {
                *visibility = if game.health <= 0. || (session.aiming && game.weapon == Weapon::Awp)
                {
                    Visibility::Hidden
                } else {
                    Visibility::Inherited
                };
            }
            if bomb.is_some() {
                *visibility = if matches!(game.bomb.state, BombState::Planted | BombState::Dropped)
                {
                    Visibility::Inherited
                } else {
                    Visibility::Hidden
                };
            }
        }
    }
    for shot in &game.shots {
        let from = Vec3::from_array(shot.from);
        let to = Vec3::from_array(shot.to);
        let delta = to - from;
        // A shot starting inside cover/an operator has zero travel. A zero-vector
        // rotation would produce an invalid transform in the rendering pipeline.
        if delta.length_squared() < 0.000001 || !delta.is_finite() {
            continue;
        }
        commands.spawn((
            Effect {
                life: 0.045,
                velocity: Vec3::ZERO,
                gravity: 0.,
            },
            Mesh3d(assets.cube.clone()),
            MeshMaterial3d(assets.tracer.clone()),
            Transform::from_translation((from + to) * 0.5)
                .with_rotation(Quat::from_rotation_arc(Vec3::Z, delta.normalize_or_zero()))
                .with_scale(Vec3::new(0.012, 0.012, delta.length())),
            NotShadowCaster,
        ));
        // Range endpoints and bot target positions are not solid surfaces.
        // Only a real world collision can leave sparks or a fixed bullet mark.
        if shot.impact == rules::Impact::World {
            for i in 0..4 {
                commands.spawn((
                    Effect {
                        life: 0.2 + i as f32 * 0.04,
                        velocity: Vec3::new((i as f32 * 2.2).sin(), 1.2, (i as f32 * 3.7).cos()),
                        gravity: 3.,
                    },
                    Mesh3d(assets.sphere.clone()),
                    MeshMaterial3d(assets.spark.clone()),
                    Transform::from_translation(to).with_scale(Vec3::splat(0.025)),
                    NotShadowCaster,
                ));
            }
        }
        if shot.impact == rules::Impact::World {
            commands.spawn((
                Effect {
                    life: 5.,
                    velocity: Vec3::ZERO,
                    gravity: 0.,
                },
                Mesh3d(assets.sphere.clone()),
                MeshMaterial3d(assets.mark.clone()),
                Transform::from_translation(to).with_scale(Vec3::splat(0.035)),
                NotShadowCaster,
            ));
        }
    }
}

pub fn sync_hud(
    time: Res<Time>,
    real_time: Res<Time<Real>>,
    sim: Res<Simulation>,
    mut session: ResMut<Session>,
    player: Single<&Transform, With<Player>>,
    #[cfg(not(target_arch = "wasm32"))] mut hud: Single<&mut Text, With<NativeHud>>,
) {
    session.hud_timer -= time.delta_secs();
    if session.hud_timer > 0. {
        return;
    }
    session.hud_timer = 0.05;
    let g = &sim.0;
    #[cfg(target_arch = "wasm32")]
    {
        let phase = match g.phase {
            Phase::Buy => "buy",
            Phase::Live => "live",
            Phase::End => "end",
            Phase::Finished => "finished",
        };
        let bomb = match g.bomb.state {
            BombState::Carried => "carried",
            BombState::Dropped => "dropped",
            BombState::Planted => "planted",
            BombState::Defused => "defused",
            BombState::Exploded => "exploded",
        };
        let bots:Vec<_>=g.bots.iter().enumerate().map(|(i,b)|serde_json::json!({"name":rules::NAMES[i],"team":if b.team==Team::Ct {"CT"} else {"T"},"x":b.pos.x,"z":b.pos.z,"health":b.health,"kills":b.kills,"deaths":b.deaths,"spotted":b.spotted,"flash":b.flash,"intent":b.intent.label()})).collect();
        let feed:Vec<_>=g.feed.iter().map(|f|serde_json::json!({"killer":f.killer,"victim":f.victim,"ct":f.team==Team::Ct,"headshot":f.headshot})).collect();
        let map: Vec<&[u8]> = g.map.tiles.iter().map(|row| row.as_slice()).collect();
        let mut data = serde_json::json!({
            "phase":phase,"round":g.round,"time":g.clock,"phaseTime":g.phase_time,"buyTime":g.buy_time,"scores":g.scores,"health":g.health,"armor":g.armor,"money":g.money,
            "weapon":g.weapon.spec().name,"slot":g.weapon.slot(),"ammo":g.ammo,"reserve":g.reserve,"reload":g.reload,"reloadTime":g.weapon.spec().reload,
            "kills":g.kills,"deaths":g.deaths,"alive":[g.alive(Team::Ct),g.alive(Team::T)],"bots":bots,"feed":feed,"map":map,
            "x":g.pos.x,"z":g.pos.z,"yaw":player.rotation.to_euler(EulerRot::YXZ).0,"aiming":session.aiming,"moving":session.moving,"recoil":session.recoil,
            "bomb":{"state":bomb,"site":if g.bomb.site==0 {"A"} else {"B"},"x":g.bomb.pos.x,"z":g.bomb.pos.z,"time":g.bomb.timer,"defuse":g.bomb.defuse,"defuser":g.bomb.defuser,"near":g.pos.distance(g.bomb.pos)<1.7},
            "winner":if g.winner==Team::Ct {"CT"} else {"T"},"reason":g.reason,"notice":if g.notice_time>0. {g.notice} else {""},
            "hitmarker":g.hitmarker,"headshot":g.headshot,"damage":g.damage_flash,"shots":g.shot_serial,"hurts":g.hurt_serial,"eliminations":g.kill_serial,
            "spectating":rules::NAMES[session.spectator],"fps":1./real_time.delta_secs().max(0.001),"started":session.started
        });
        data["spawn"] = serde_json::json!([rules::PLAYER_SPAWN.x, rules::PLAYER_SPAWN.z]);
        data["attackerSpawn"] = serde_json::json!([rules::T_SPAWNS[2].x, rules::T_SPAWNS[2].z]);
        data["sites"] = serde_json::json!(rules::SITES.map(|s| [s.x, s.z]));
        data["layoutScale"] = serde_json::json!(rules::LAYOUT_SCALE);
        data["spread"] = serde_json::json!(g.spread(session.moving, session.aiming));
        data["bloom"] = serde_json::json!(g.bloom);
        data["pitch"] = serde_json::json!(player.rotation.to_euler(EulerRot::YXZ).1);
        data["elevation"] = serde_json::json!(g.map.elevation(g.pos.x, g.pos.z));
        data["seed"] = serde_json::json!(g.seed);
        data["quality"] = serde_json::json!(if session.low_quality {
            "low"
        } else {
            "standard"
        });
        browser::hud(&data.to_string());
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let status = if !session.started {
            "CLICK / ENTER TO DEPLOY"
        } else if !session.active {
            "PAUSED — ENTER TO RESUME"
        } else {
            g.notice
        };
        **hud = Text::new(format!(
            "DUSTLINE: FIELD TRIALS   CT {} : {} T   ROUND {}\n{status}\nHP {:.0}  ARMOR {:.0}  ${}    {}  {} / {}\n{:?}  {:.0}s    BOMB {:?} {:.0}s\n{}\nWASD move · Shift walk · Ctrl crouch · RMB aim · R reload · E defuse · B buy · Esc pause\n{}",
            g.scores[0],
            g.scores[1],
            g.round,
            g.health,
            g.armor,
            g.money,
            g.weapon.spec().name,
            g.ammo,
            g.reserve,
            g.phase,
            if g.phase == Phase::Buy {
                g.phase_time
            } else {
                g.clock
            },
            g.bomb.state,
            g.bomb.timer,
            g.reason,
            if session.shop {
                "BUY: 1 M4 $3100 | 2 AK $2700 | 3 AWP $4750 | 4 DEAGLE $700"
            } else {
                ""
            }
        ));
        let _ = (&player, &real_time);
    }
}

pub fn spawn_landmarks(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    map: &rules::Map,
) {
    let cube = meshes.add(Cuboid::new(1., 1., 1.));
    let sphere = meshes.add(Sphere::new(1.));
    let tracer = materials.add(StandardMaterial {
        base_color: Color::srgb(1., 0.73, 0.32),
        emissive: LinearRgba::new(5., 2., 0.2, 1.),
        unlit: true,
        ..default()
    });
    let spark = materials.add(StandardMaterial {
        base_color: Color::srgb(1., 0.8, 0.38),
        emissive: LinearRgba::new(4., 2., 0.3, 1.),
        ..default()
    });
    let mark = materials.add(Color::srgb(0.07, 0.05, 0.035));
    commands.insert_resource(EffectAssets {
        cube: cube.clone(),
        sphere,
        tracer,
        spark,
        mark: mark.clone(),
    });
    let paint = materials.add(StandardMaterial {
        base_color: Color::srgb(0.91, 0.48, 0.19),
        perceptual_roughness: 0.95,
        ..default()
    });
    let ivory = materials.add(Color::srgb(0.86, 0.8, 0.61));
    let teal = materials.add(StandardMaterial {
        base_color: Color::srgb(0.055, 0.22, 0.24),
        perceptual_roughness: 0.85,
        ..default()
    });
    // Ground markings and large site signs are readable landmarks in the 3D space.
    for (index, site) in rules::SITES.iter().enumerate() {
        for (offset, size) in [
            (Vec3::new(-1.9, 0.055, 0.), Vec3::new(0.065, 0.015, 3.8)),
            (Vec3::new(1.9, 0.055, 0.), Vec3::new(0.065, 0.015, 3.8)),
            (Vec3::new(0., 0.055, -1.9), Vec3::new(3.8, 0.015, 0.065)),
            (Vec3::new(0., 0.055, 1.9), Vec3::new(3.8, 0.015, 0.065)),
        ] {
            commands.spawn((
                Mesh3d(cube.clone()),
                MeshMaterial3d(ivory.clone()),
                Transform::from_translation(
                    Vec3::new(site.x, map.elevation(site.x, site.z), site.z) + offset,
                )
                .with_scale(size),
            ));
        }
        let sign = Vec3::new(site.x, 2.1, 4.012);
        commands.spawn((
            Mesh3d(cube.clone()),
            MeshMaterial3d(teal.clone()),
            Transform::from_translation(sign).with_scale(Vec3::new(1.2, 1.15, 0.035)),
        ));
        let segments = if index == 0 {
            vec![
                (
                    Vec3::new(-0.19, 0., 0.04),
                    Vec3::new(0.09, 0.8, 0.02),
                    -0.35,
                ),
                (Vec3::new(0.19, 0., 0.04), Vec3::new(0.09, 0.8, 0.02), 0.35),
                (Vec3::new(0., -0.08, 0.04), Vec3::new(0.38, 0.08, 0.02), 0.),
            ]
        } else {
            vec![
                (Vec3::new(-0.24, 0., 0.04), Vec3::new(0.08, 0.8, 0.02), 0.),
                (Vec3::new(0.04, 0.36, 0.04), Vec3::new(0.55, 0.08, 0.02), 0.),
                (Vec3::new(0.04, 0., 0.04), Vec3::new(0.55, 0.08, 0.02), 0.),
                (
                    Vec3::new(0.04, -0.36, 0.04),
                    Vec3::new(0.55, 0.08, 0.02),
                    0.,
                ),
                (Vec3::new(0.27, 0., 0.04), Vec3::new(0.08, 0.72, 0.02), 0.),
            ]
        };
        for (offset, size, angle) in segments {
            commands.spawn((
                Mesh3d(cube.clone()),
                MeshMaterial3d(paint.clone()),
                Transform::from_translation(sign + offset)
                    .with_rotation(Quat::from_rotation_z(angle))
                    .with_scale(size),
            ));
        }
    }
    // Shuttered windows, cornices and antennas give the skyline a sense of place.
    for (x, z, width, height) in [
        (9., 0.8, 4., 5.2),
        (20., 0.8, 3., 6.1),
        (30.8, 9., 2., 4.8),
        (0.8, 14., 2., 6.5),
        (10.5, 14., 3., 4.1),
        (21., 10.5, 2.5, 4.5),
    ] {
        let p = layout_position(x, 0., z);
        let base = map.elevation(p.x, p.z);
        commands.spawn((
            Mesh3d(cube.clone()),
            MeshMaterial3d(ivory.clone()),
            Transform::from_xyz(p.x, base + height / 2., p.z).with_scale(Vec3::new(
                width * 2.,
                height,
                2.8,
            )),
        ));
        commands.spawn((
            Mesh3d(cube.clone()),
            MeshMaterial3d(teal.clone()),
            Transform::from_xyz(p.x, base + height - 1.2, p.z + 1.42)
                .with_scale(Vec3::new(0.85, 1.2, 0.07)),
        ));
        commands.spawn((
            Mesh3d(cube.clone()),
            MeshMaterial3d(mark.clone()),
            Transform::from_xyz(p.x + 0.4, base + height + 0.5, p.z)
                .with_scale(Vec3::new(0.035, 1.2, 0.035)),
        ));
        commands.spawn((
            Mesh3d(cube.clone()),
            MeshMaterial3d(mark.clone()),
            Transform::from_xyz(p.x + 0.4, base + height + 0.8, p.z)
                .with_scale(Vec3::new(0.85, 0.025, 0.025)),
        ));
    }
    commands
        .spawn((
            BombVisual,
            Mesh3d(cube),
            MeshMaterial3d(teal),
            Transform::from_xyz(0., 0.13, 0.).with_scale(Vec3::new(0.32, 0.22, 0.23)),
            Visibility::Hidden,
        ))
        .with_children(|bomb| {
            bomb.spawn((
                Mesh3d(meshes.add(Cuboid::new(0.5, 0.12, 0.5))),
                MeshMaterial3d(materials.add(StandardMaterial {
                    base_color: Color::srgb(1., 0.1, 0.02),
                    emissive: LinearRgba::new(5., 0.05, 0., 1.),
                    ..default()
                })),
                Transform::from_xyz(0., 0.55, 0.),
            ));
        });
}
