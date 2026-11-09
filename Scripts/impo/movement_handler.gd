extends Node
@export var skeleton: Skeleton2D
@export var rigid: RigidBody2D
@export var rigidtorso: RigidBody2D
@export var animplay: AnimationPlayer
@export var eyes: Sprite2D
@export var tail: Bone2D
@export var skelparent: Node2D
@export var headIk: Node2D
@export var headIkControl: SoupLookAt


#collisions via stat
@export var normal: CollisionShape2D
@export var sitting: CollisionShape2D
@export var layingdown: CollisionShape2D
#raycasts
@export var floorRay: RayCast2D
@export var wallDetect: RayCast2D
@export var heightDetect: RayCast2D

@export var defheadnose: Node2D

@export var ragdollspeed: float = 575.0

@export var pinNode: Node2D

signal sigragdoll()

var lookback = false
var flip = false
var backwards = false
var dir: float = 0.0
var wander = true
var friction: float = 1.0
var speedacc: float = 20.0
var maxspeed: float = 240.0 # you will understand what the one is for later
const ANIM_REF_SPEED := 240.0 # обычная скорость ходьбы - от неё считается скорость анимации шагов
var maxspeedMult: float = 10.0
#i literally forgot what the one was for
var jumpPowCap: float = -600.0
var jumpPower: float = -600.0
#timers

@export var jumpCoolDown: float = 4.0
var jumpTimer: float = 0.0

#pin joint storers
var valAngularPinUp
var valAngularPinDown
var notragdolled = true

enum states {
	moving, idle, ragdoll, jumping, falling, resting
}
var currstate = states.idle


func _ready() -> void:
	_collectJoints() # до первого кадра: части тела ещё в позе сцены (как при создании шарниров)
	animplay.play("idleagain")

	#invertPoints(false, true)
	call_deferred("_attachLiveBody")


## F1 «Живая физика» (Scripts/impo/live_body.gd): плавное вставание и живые руки, голова, хвост.
var liveBody = null

## F2 (по мотивам Casualties: Unknown, Body.FixedUpdate/TryStepUp/Jump): при «живой физике» -
## плавный разгон и торможение, наклон тела от ускорения, присед при приземлении, шаг вверх
## на низкие предметы без прыжка, «время койота» для прыжка. Выключена - ходьба как в K2.
## Картинку (наклон, присед, отставание) рисует LiveBody (live_body.gd), здесь - только числа.
## F2.1 (тест Alex F2: «ходят будто в замедленном режиме, в 2-2,5 раза медленнее»): старая ходьба
## из-за рывка силы шла не 240, а в среднем 386 px/с (стенд, живая физика выкл) - скорость K2
## возвращена множителем; анимация шагов считается от скорости, лапы не скользят.
const CU_WALK_MULT := 1.6 # 240 * 1,6 = 384 px/с - как в среднем ходили в K2
const CU_ACCEL := 2600.0 # px/с² - до 90 % скорости за ~0,2 с с трением (было 1600 при 240)
## F2.1 (Alex: «прыжок низкий, увеличить в 1,4-1,6 раза»): высота x1,5 = скорость прыжка x1,22
const CU_JUMP_MULT := 1.22
const CU_ANIM_MULT := 0.945 # шаги на 5,5 % медленнее (Alex: «уменьшить на 4-7 %»)
## F2.3 (тест Alex F2.2: «без живой физики встаёт слишком быстро, как ctrl+z»): раньше без живой физики
## персонаж вставал чуть над землёй и приземлялся (так выходило из-за двойного переноса) - вернули нарочно.
const OFF_STAND_LIFT := 70.0 # px при масштабе 4
const CU_AIR_ACCEL := 900.0 # px/с² - в воздухе управлять слабее
const CU_SLOWDOWN := 0.18 # доля скорости, гаснущая за шаг физики без нажатия или при развороте (в воздухе - половина)
const CU_LEAN_PER_DV := 0.30 # градусов наклона на 1 px/с изменения скорости за шаг (CU: 15° на ед. ~ 0,28); при разгоне 2600 - ~6°
const CU_LEAN_RATE := 5.0 # CU: Lerp(accelRot, ..., fixedDeltaTime * 5)
const CU_LEAN_MAX := 25.0 # градусов
const CU_COYOTE := 0.11 # с - прыгнуть можно ещё столько после схода с края (CU)
const CU_LAND_CROUCH := 0.05 # px приседа на 1 px/с скорости падения (CU: crouchAmount -= vy * 0,03); прыжок -> ~35 px
const CU_LAND_CROUCH_MAX := 55.0 # px - глубже не приседает (F2.1, Alex: «спрыгнул с двух ящиков - просто приземлился»; было 0,025 и 40)
const CU_LAND_MIN := 150.0 # px/с - мягче этого приземление не считается
const CU_STEP_FRAC := 0.35 # шаг вверх - не выше этой доли роста
var lean := 0.0 # градусы, в мире: + по часовой (верх тела вправо)
var visualOffset := Vector2.ZERO # px, в мире: вся картинка отстаёт от тела (шаг вверх) и догоняет (LiveBody)
var _landCooldown := 0.0
var crouch := 0.0 # px, в мире: присед - таз ниже, ступни на месте (приземление, вставание); гаснет в LiveBody
var _lastVel := Vector2.ZERO
var _sinceGrounded := 0.0
var _wasGrounded := true
var lastStepUpMsec := -100000 # для стенда
var stepUps := 0 # для стенда: сколько раз шагнул вверх


func _cuLive() -> bool:
	return liveBody != null and liveBody.enabled() and notragdolled

func _attachLiveBody() -> void:
	liveBody = preload("res://Scripts/impo/live_body.gd").new()
	liveBody.name = "LiveBody"
	skeleton.add_child(liveBody) # последним ребёнком скелета - после IK (SoupMod)
	liveBody.setup(self)
func _physics_process(delta: float) -> void:
	jumpTimer -= delta

	if currstate != states.resting:
		if !floorRay.is_colliding() and abs(rigid.linear_velocity.y) > 2:
			if rigid.linear_velocity.y > 0:
				initswithc(states.falling)
			else:
				initswithc(states.jumping)
		else:
			if dir != 0.0:
				initswithc(states.moving)
			else:
				initswithc(states.idle)
	else:
		# F2.7: сидящий/лежащий падает, только если пола нет дольше 0,3 с (луч на миг терял пол -
		# и персонаж вставал сам)
		_restNoFloor = 0.0 if floorRay.is_colliding() else _restNoFloor + delta
		if _restNoFloor > 0.3:
			initswithc(states.falling)
		dir = 0.0
	headIKf()
	checkJump()
	detFlip()
	phystate(delta)
	if _cuLive():
		_cuPhysics(delta)
	else:
		lean = 0.0
		crouch = 0.0
		visualOffset = Vector2.ZERO
		_sinceGrounded = 0.0 if floorRay.is_colliding() else _sinceGrounded + delta
		_lastVel = rigid.linear_velocity
	rigidtorso.linear_velocity = rigidtorso.linear_velocity.clamp(Vector2(
		- maxspeed * maxspeedMult, -maxspeed * maxspeedMult), Vector2(maxspeed * maxspeedMult, maxspeed * maxspeedMult)
		)

	pass


## F2: то, что у CU в FixedUpdate после разгона: торможение, предел скорости на земле, воздух,
## шаг вверх, наклон от ускорения, проседание при приземлении.
func _cuPhysics(delta: float) -> void:
	var grounded: bool = floorRay.is_colliding()
	var v: Vector2 = rigid.linear_velocity
	var resting: bool = currstate == states.resting
	if not resting:
		# разгон (CU: AddForce(moveForce), пока медленнее предела) - за ~0,2 с, а не за один шаг:
		# прежняя сила давала +333 px/с за шаг, и скорость прыгала до 560 при пределе 240
		var sk := _sizeK()
		var tempmax: float = (maxspeed if not backwards else maxspeed / 2.0 + 40.0) * CU_WALK_MULT * sk
		if dir != 0.0 and (signf(v.x) != signf(dir) or absf(v.x) < tempmax):
			v.x += dir * (CU_ACCEL if grounded else CU_AIR_ACCEL) * sk * delta
			if signf(v.x) == signf(dir) and absf(v.x) > tempmax:
				v.x = dir * tempmax
		# торможение: нет нажатия или разворот - скорость гаснет долей за шаг (CU)
		if dir == 0.0 or signf(v.x) == -signf(dir):
			v.x *= 1.0 - CU_SLOWDOWN * (1.0 if grounded else 0.5)
		if grounded and absf(v.x) > maxspeed * CU_WALK_MULT * sk * 1.05:
			v.x = signf(v.x) * maxspeed * CU_WALK_MULT * sk # на земле - не быстрее предела (CU)
		rigid.linear_velocity = v
		if grounded and dir != 0.0:
			_cuStepUp()
	# приземление: присед пропорционально скорости падения (CU OnCollisionEnter2D: crouchAmount -= vy * 0,03).
	# F2.1: в момент удара - когда падение остановилось, а не когда луч под ногами впервые увидел пол
	# (луч длиннее ног: присед начинался ещё в воздухе, на скорости 700 px/с - стенд)
	# F2.3: не чаще раза в 0,3 с - подскоки тела на полу засчитывались новыми приземлениями, присед копился
	# (тест Alex F2.2: «в конце концов перс принимает позу сидя, ноги под панелью задач»)
	_landCooldown = maxf(0.0, _landCooldown - delta)
	if grounded and _lastVel.y > CU_LAND_MIN and rigid.linear_velocity.y < _lastVel.y * 0.5 and _landCooldown <= 0.0:
		crouch = minf(crouch + _lastVel.y * CU_LAND_CROUCH, CU_LAND_CROUCH_MAX)
		_landCooldown = 0.3
	_sinceGrounded = 0.0 if grounded else _sinceGrounded + delta
	_wasGrounded = grounded
	# наклон от ускорения (CU: accelRot = Lerp(accelRot, dv * 15 * k, fixedDeltaTime * 5))
	var dv: float = rigid.linear_velocity.x - _lastVel.x
	var target := clampf(dv * CU_LEAN_PER_DV, -CU_LEAN_MAX, CU_LEAN_MAX)
	lean = lerpf(lean, target, clampf(delta * CU_LEAN_RATE, 0.0, 1.0))
	_lastVel = rigid.linear_velocity


## F2: шаг вверх (CU TryStepUp): у ног впереди препятствие, над ним свободно, верх не выше доли
## роста - тело переносится наверх без прыжка, картинка остаётся на месте и догоняет.
func _cuStepUp() -> void:
	if not normal or normal.disabled or not (normal.shape is CapsuleShape2D):
		return
	var cap := normal.shape as CapsuleShape2D
	var sc: Vector2 = normal.global_transform.get_scale().abs()
	var halfW: float = cap.radius * sc.x
	var height: float = cap.height * sc.y
	var center: Vector2 = normal.global_position
	var bottom: float = center.y + height * 0.5
	var maxStep: float = height * CU_STEP_FRAC
	var space := rigid.get_world_2d().direct_space_state
	var ex: Array[RID] = [rigid.get_rid()]
	for b in rigid.find_children("*", "CollisionObject2D", true, false):
		ex.append(b.get_rid())
	var q := PhysicsRayQueryParameters2D.create(Vector2(center.x, bottom - 3.0), Vector2(center.x + dir * (halfW + 14.0), bottom - 3.0), 1, ex)
	var hit := space.intersect_ray(q)
	if hit.is_empty() or hit["collider"] == noJumpOver:
		return
	var hp: Vector2 = hit["position"]
	var probe := Vector2(hp.x + dir * 6.0, bottom - maxStep - 2.0)
	# над ступенькой свободно на рост тела (иначе это стена, а не ступенька)
	var qUp := PhysicsRayQueryParameters2D.create(probe, probe - Vector2(0.0, height), 1, ex)
	if not space.intersect_ray(qUp).is_empty():
		return
	# верх ступеньки - луч сверху вниз
	var qDown := PhysicsRayQueryParameters2D.create(probe, Vector2(probe.x, bottom), 1, ex)
	var top := space.intersect_ray(qDown)
	if top.is_empty():
		return
	var stepH: float = bottom - float(top["position"].y)
	if stepH < 2.0 or stepH > maxStep:
		return
	var move := Vector2(dir * maxf(0.0, (hp.x - center.x) * dir - halfW), -(stepH + 2.0))
	rigid.global_position += move
	visualOffset -= move # картинка остаётся на месте и догоняет (LiveBody)
	rigid.linear_velocity.x = _lastVel.x
	lastStepUpMsec = Time.get_ticks_msec()
	stepUps += 1

#make them look at any object with a priority over 4

func headIKf():
	var dectNode = get_parent().detectRange
	var inRadius = dectNode.inRadius
	var mousePriority = dectNode.mousePriority
	var facing: float = -1.0 if flip else 1.0

	
	var targetPos: Vector2 = headIk.get_global_mouse_position()

	var mostInterest: float = mousePriority

	for obj in inRadius.keys():
		var data = inRadius[obj]
		if data.has("interest") and data["interest"] > mostInterest:
			mostInterest = data["interest"]
			targetPos = obj.global_position

	var dirx: float = sign(targetPos.x - rigidtorso.global_position.x)
	var mouse_pos: Vector2 = targetPos
	var dist: float = rigidtorso.global_position.distance_to(targetPos)

	if dist <= 750.0:
		lookback = dirx != facing
		# 055.0001: цель за спиной - голова не поворачивается (раньше запрокидывалась),
		# назад косятся только глаза (lookback -> спрайт "back" в faceSys).
		if lookback:
			mouse_pos = defheadnose.global_position

		headIk.global_position = headIk.global_position.lerp(mouse_pos, .05)
	else:
		lookback = false
		headIk.global_position = headIk.global_position.lerp(defheadnose.global_position, .05)


#initial switch state 
func initswithc(state: states):
	if currstate == state: return
	currstate = state
	match state:
		states.idle:
			switch_hitbox(1)
			self.get_parent().wander = true
			animplay.speed_scale = 1
			animplay.play("idleagain")
			pass # отладочный вывод убран (054.99)
			pass
		states.jumping:
			switch_hitbox(1)
			self.get_parent().wander = true
			animplay.speed_scale = 1
			animplay.play("jump")
			print("jump")
		states.falling:
			switch_hitbox(1)
			self.get_parent().wander = true
			pass # отладочный вывод убран (054.99)
			animplay.speed_scale = 1
			animplay.play("fall")
		states.moving:
			switch_hitbox(1)
			self.get_parent().wander = true
			pass # отладочный вывод убран (054.99)

		states.resting:
			pass # отладочный вывод убран (054.99)
			self.get_parent().wander = false
			var r = randi_range(1, 2)
			if forcedRestPose != 0: # просьба игрока "сядь"/"ляг" (behavior._doChatAction)
				r = forcedRestPose
				forcedRestPose = 0
			var resttime = randi_range(120, 200)
			# F2.7 (чек-лист Alex: «сядь/ляг» - а перс сразу встаёт): по просьбе - 5 минут (раньше
			# встать - только от удара, захвата или новой просьбы)
			if restCommanded:
				restCommanded = false
				resttime = COMMANDED_REST_SEC
			_restToken += 1
			var myRest := _restToken
			_restNoFloor = 0.0
			animplay.play("sit" if r == 1 else "laydown")

			switch_hitbox(2 if r == 1 else 3)
			await get_tree().create_timer(resttime).timeout
			# F2.7: таймер прошлого отдыха больше не поднимает с нового (садился сам, встал, сел по просьбе -
			# старый таймер срабатывал посреди нового отдыха)
			if myRest != _restToken or currstate != states.resting:
				return
			initswithc(states.idle)
			self.get_parent().wander = true


	pass


func switch_hitbox(state: int):
	normal.disabled = (state != 1)
	sitting.disabled = (state != 2)
	layingdown.disabled = (state != 3)


func phystate(_delta: float):
	match currstate:
		states.idle:
			rigid.linear_velocity.x = move_toward(rigid.linear_velocity.x, 0, friction)

			pass
		states.moving:
			var tempmax = maxspeed * _sizeK()
			#apply movement based on direction
			if backwards:
				tempmax = (tempmax / 2) + 40
			var moving_same_direction = sign(rigid.linear_velocity.x) == dir

			if !moving_same_direction or abs(rigid.linear_velocity.x) < tempmax:
				if not _cuLive(): # F2: при живой физике разгон - в _cuPhysics (через скорость, без рывка)
					rigid.apply_central_force(Vector2(dir, 0) * speedacc * _sizeK())

		
			# Анимация считается от ОБЫЧНОЙ скорости, а не от текущего лимита:
			# behavior._walkTo() временно снижает maxspeed (усталость, фентанил),
			# и раньше ноги от этого перебирали быстрее при меньшей скорости.
			var normlized = abs(remap(rigid.linear_velocity.x, 0, ANIM_REF_SPEED * _sizeK(), 0.0, 1.0))
			#there used to be a long if statement here and my ass got flamed when i posted it
			backwards = GlobalVariable.checkpositive(dir) == flip
			var target_anim = "moveB" if backwards else "moveF"

			if animplay.current_animation != target_anim:
				animplay.play(target_anim)

			animplay.speed_scale = (normlized / 2) + .1
			if _cuLive():
				animplay.speed_scale *= CU_ANIM_MULT # F2.3 (Alex: «анимация будто идёт быстрее, чем идёт перс»)
			
			
			pass


## Игрок под управлением смотрит по направлению движения, а не на курсор -
## иначе при ходьбе "от курсора" включалась медленная ходьба задом.
var faceMoveDir := false
## 1 - сесть, 2 - лечь: следующий отдых примет эту позу, а не случайную
var forcedRestPose := 0
var restCommanded := false # F2.7: отдых по просьбе игрока - дольше (COMMANDED_REST_SEC)
const COMMANDED_REST_SEC := 300
var _restToken := 0
var _restNoFloor := 0.0

func detFlip():
	if currstate == states.ragdoll:
		return
	# F1: пока тело перетекает из позы лёжа в анимацию - не разворачиваться (поза лёжа
	# не зеркальная, смешивать её с зеркальной нельзя)
	if liveBody != null and liveBody.blending:
		return
	if faceMoveDir:
		if dir != 0:
			skelparent.scale.x = dir
			flip = dir < 0
		return

	var dirx: float = sign(rigid.get_global_mouse_position().x - rigid.global_position.x)
	var _facing: float = -1.0 if flip else 1.0

		
	if dirx == dir:
		if dir != 0:
			skelparent.scale.x = dir
		if dir == 1:
			flip = false
		else:
			flip = true

		#invertPoints(flip)
		pass
	#determine when you gotta FLIPPPP
	pass

#test function 
#invert pinjoin angular limits

func invertPoints(val: bool, setup: bool = false):
	print(pinNode)
	var descendants = pinNode.find_children("*", "", true, false)

	for child in descendants:
		if child is PinJoint2D or child is RapierPinJoint2D:
			"""
			var fuckyou: RapierPinJoint2D
			fuckyou.angular_limit_lower
			fuckyou.angular_limit_upper
			"""

			if setup:
				#reset default limits i do not recommend calling this more than one time
				valAngularPinDown = child.angular_limit_lower
				valAngularPinUp = child.angular_limit_upper
				return

			
			if val:
				child.angular_limit_lower = valAngularPinUp
				child.angular_limit_upper = valAngularPinDown
			else:
				child.angular_limit_lower = valAngularPinDown
				child.angular_limit_upper = valAngularPinUp


## 0.56 (тест Alex 055.008, EN: Експи не дошёл до сока): к чему идём по просьбе -
## через то не прыгаем (раньше перепрыгивал сам сок и уходил дальше).
var noJumpOver: Node = null

func checkJump():
	if faceMoveDir:
		return # перс-игрок под управлением прыгает только сам (W/пробел), без автопрыжка через препятствия
	if noJumpOver != null and is_instance_valid(noJumpOver) and wallDetect.is_colliding() and wallDetect.get_collider() == noJumpOver:
		return
	if wallDetect.is_colliding() and !heightDetect.is_colliding() and dir != 0.0 and !backwards:
		jump()
	pass

## Когда был последний собственный прыжок: behavior не считает этот рывок
## скорости ударом о землю (с зажатым прыжком перс-игрок получал урон).
var lastJumpMsec := -100000

## force - осознанный прыжок (упёрся по дороге, behavior._hopOver): без перезарядки автопрыжка.
## F2.1 (тест Alex F2: «столкнула себя предметом AR-15»): капсула персонажа весит 0,001 - толкая предмет
## или прыгая через него, её отбрасывает до 600-1100 px/с, и раньше это считалось «споткнулась» (рэгдолл).
## С живой физикой - только пошатнулась: скорость в пределах ходьбы, тело качнуло в сторону толчка.
func stumble() -> void:
	var v: Vector2 = rigid.linear_velocity
	var lim: float = maxspeed * CU_WALK_MULT * _sizeK()
	lean = clampf(lean + signf(v.x) * 14.0, -CU_LEAN_MAX, CU_LEAN_MAX)
	v.x = clampf(v.x, -lim, lim)
	v.y = maxf(v.y, jumpPower * CU_JUMP_MULT * sqrt(_sizeK()))
	rigid.linear_velocity = v
	_lastVel = v


## F2: «время койота» (CU: timeSinceGrounded <= 0,11) - при живой физике прыжок срабатывает
## ещё 0,11 с после схода с края (назван в честь Хитрого Койота, который висит над обрывом).
## F2.7 (тестер, petScale 3: «ходят очень быстро»): скорость - в пикселях, а персонаж меньше - и шагал
## в 1,33 раза быстрее себя. Скорость ходьбы - пропорционально размеру, прыжок - как корень (высота
## прыжка тогда тоже пропорциональна росту). Размер 4 (обычный) - всё как было.
func _sizeK() -> float:
	return float(gbData.settings.get("petScale", 4.0)) / 4.0

func jump(force: bool = false):
	var onFloor: bool = floorRay.is_colliding() or (_cuLive() and _sinceGrounded <= CU_COYOTE)
	if onFloor and (force or jumpTimer <= 0.0):
		var vel = rigid.linear_velocity
		vel.y = jumpPower * (CU_JUMP_MULT if _cuLive() else 1.0) * sqrt(_sizeK())
		rigid.linear_velocity = vel
		jumpTimer = jumpCoolDown
		lastJumpMsec = Time.get_ticks_msec()
		_sinceGrounded = CU_COYOTE + 1.0 # второй раз в воздухе - нельзя


func ragdoll(val: bool):
	#true = not ragdolled
	#false = ragdolled
	if val == notragdolled:
		return
	# F2.1: где лежит туловище - ДО всего остального: ниже включаются RemoteTransform (без живой физики
	# они сразу переставляют части тела в позу стоя), и капсула переносится (части тела - её дети)
	var torsoPos: Vector2 = rigidtorso.global_position
	if val:
		# F2.2: лежал зеркальным - части тела назад в обычный вид, встаёт лицом туда же, куда лежал
		if _limbsToVisual():
			skelparent.scale.x = -1.0
			flip = true
	var mirrored: bool = skelparent.scale.x < 0.0 # F2.2: падает, глядя влево (см. ниже, после разморозки)
	# F2.2: как части тела выглядят - ДО разворота скелета: ниже RemoteTransform при выключении ещё раз
	# переносят позу уже развёрнутого вправо скелета (в этом и была причина «всегда смотрит вправо»),
	# а разморозка берёт положение из физики - без зеркала
	var preXf := {}
	if !val and mirrored:
		for child in rigid.find_children("*", "RigidBody2D", true, false):
			preXf[child] = (child as Node2D).global_transform

	notragdolled = val

	if !val:
		skelparent.scale.x = 1.0

	var descendants = skeleton.find_children("*", "", true, false)
	var moredesc = rigid.find_children("*", "", true, false)
	# F1: конец рэгдолла при «живой физике» - части тела не защёлкиваются в позу, а перетекают в неё
	# (LiveBody.startBlend): их RemoteTransform включатся, когда перетекание закончится
	var smooth: bool = val and liveBody != null and liveBody.enabled()
	var limbRts: Array = []

	for child in descendants:
		if child is RemoteTransform2D:
			var rtt: RemoteTransform2D = child
			var toLimb: bool = smooth and rtt.get_node_or_null(rtt.remote_path) is RigidBody2D
			if toLimb:
				limbRts.append(rtt)
			rtt.update_position = val and not toLimb
			rtt.update_rotation = val and not toLimb
			rtt.update_scale = val and not toLimb

	for child in moredesc:
		if child is RigidBody2D:
			child.freeze = val
			if !val:
			#rigid.scale.x = -1.0 if flip else 1.0
				child.linear_velocity = rigid.linear_velocity
				child.angular_velocity = rigid.angular_velocity

	#lmao


	if !val:
		# F2.2: падает, глядя влево - тело и шарниры зеркальные (раньше рэгдолл всегда смотрел вправо).
		# После разморозки: положение замороженного тела физика применяет только на следующем шаге, и
		# шарниры брали бы точки от старого (стенд: части тела расходились до 100 px).
		lastRagdollMirrored = mirrored
		if mirrored:
			for b in preXf:
				_toFlipped(b, preXf[b])
		if mirrored != _jointsMirrored:
			_setJointsMirrored(mirrored)
		if liveBody != null:
			liveBody.onRagdoll()
		sigragdoll.emit()
	else:
		# F2.1 (тест Alex F2: встаёт «сильно правее», «в другой точке экрана», «застряла в рюкзаке»):
		# капсулу переносили к туловищу дважды (здесь и в behavior.tempRagdoll), и лежащие части тела
		# (её дети) каждый раз ехали вместе с ней - персонаж вставал смещённым на столько, на сколько
		# отлетел от места падения или захвата (стенд: упала в 100 px - встала в 100 px в стороне).
		# Теперь: один перенос, части тела остаются, где лежат, ноги - на пол под туловищем, а если
		# там предмет - рядом, где свободно.
		var keep := {}
		for child in moredesc:
			if child is RigidBody2D:
				keep[child] = (child as Node2D).global_transform
		var spot := _standSpot(torsoPos)
		if not smooth and lastStandShift.y == 0.0:
			spot.y -= OFF_STAND_LIFT * absf(skeleton.global_transform.get_scale().y) / 4.0
		rigid.global_position = spot
		for b in keep:
			(b as Node2D).global_transform = keep[b]
		if smooth:
			liveBody.startBlend(limbRts) # позы «откуда» - уже после переноса тела к туловищу


## F2.2 (тест Alex F2: «когда берёшь перса, он всегда смотрит вправо, даже если развернуть влево»):
## физика не умеет зеркальные тела, а шарниры созданы для позы «смотрит вправо» - лёжа персонаж
## разворачивался. Теперь зеркальная часть тела в рэгдолле - это то же тело, повёрнутое на 180°, с
## картинками, отражёнными по вертикали (визуально то же самое, а для физики - обычное тело);
## шарниры переставляются в зеркальные места и создаются заново, пределы сгиба - зеркально.
var _joints: Array = [] # {j, a, b, localA, lo, hi} - точки шарниров в частях тела из позы сцены
var _jointsMirrored := false
var lastRagdollMirrored := false # для стенда

func _collectJoints() -> void:
	_joints.clear()
	if pinNode == null:
		return
	for j in pinNode.find_children("*", "PinJoint2D", true, false):
		var a := j.get_node_or_null(j.node_a) as Node2D
		var b := j.get_node_or_null(j.node_b) as Node2D
		if a == null or b == null:
			continue
		_joints.append({"j": j, "a": a, "b": b,
			"localA": a.global_transform.affine_inverse() * (j as Node2D).global_position,
			"localB": b.global_transform.affine_inverse() * (j as Node2D).global_position,
			"lo": float(j.angular_limit_lower), "hi": float(j.angular_limit_upper),
			"rest": wrapf(b.global_transform.get_rotation() - a.global_transform.get_rotation(), -PI, PI)})


## Как часть тела выглядит (зеркальная лёжа - через поворот на 180° и отражённые картинки).
func visualXf(b: Node2D) -> Transform2D:
	return b.global_transform * Transform2D.FLIP_Y if b.get_meta("yflip", false) else b.global_transform


## Отразить ребёнка части тела по её оси y (картинки - вместе с масштабом, формы и области - только место).
func flipNode(c: Node2D) -> void:
	c.position.y = -c.position.y
	c.rotation = -c.rotation
	if c is Sprite2D or c is AnimatedSprite2D or c is Polygon2D:
		c.scale.y = -c.scale.y
	c.set_meta("yflipped", not bool(c.get_meta("yflipped", false)))


func _toFlipped(b: Node2D, src: Transform2D) -> void:
	if b.get_meta("yflip", false):
		return
	b.global_transform = src * Transform2D.FLIP_Y
	for c in b.get_children():
		if c is Node2D:
			flipNode(c)
	b.set_meta("yflip", true)
	_syncBody(b)


## Новое положение части тела - в физику сразу (узел сообщает его только в конце кадра, а шарниры
## создаются сейчас и берут точки от того, что знает физика; стенд F2.2: части тела расходились до 100 px).
func _syncBody(b: Node2D) -> void:
	if b is CollisionObject2D:
		PhysicsServer2D.body_set_state((b as CollisionObject2D).get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, b.global_transform)


## Все части тела - в обычный вид; true, если были зеркальными.
func _limbsToVisual() -> bool:
	var was := false
	for b in rigid.find_children("*", "RigidBody2D", true, false):
		if not b.get_meta("yflip", false):
			continue
		was = true
		b.global_transform = b.global_transform * Transform2D.FLIP_Y
		for c in b.get_children():
			if c is Node2D and c.get_meta("yflipped", false):
				flipNode(c)
		b.set_meta("yflip", false)
	return was


func _setJointsMirrored(m: bool) -> void:
	for e in _joints:
		if is_instance_valid(e["a"]):
			_syncBody(e["a"])
		if is_instance_valid(e["b"]):
			_syncBody(e["b"])
	for e in _joints:
		var j: PinJoint2D = e["j"]
		if not is_instance_valid(j) or not is_instance_valid(e["a"]):
			continue
		# шарнир - туда, где он сейчас на части тела A (по её точке из позы сцены)
		var visA: Transform2D = visualXf(e["a"])
		j.global_position = visA * (e["localA"] as Vector2)
		if m:
			j.angular_limit_lower = -float(e["hi"])
			j.angular_limit_upper = -float(e["lo"])
		else:
			j.angular_limit_lower = float(e["lo"])
			j.angular_limit_upper = float(e["hi"])
		var na: NodePath = j.node_a
		j.node_a = NodePath("")
		j.node_a = na # шарнир создаётся заново - с новыми точками
	_jointsMirrored = m


## F2.1: где встать: ноги - на пол (или предмет) под туловищем; если капсуле там тесно (лежит под
## предметом, рядом ящик) - ближайшее свободное место: левее-правее, потом выше (на предмет).
var lastStandShift := Vector2.ZERO # для стенда: насколько сдвинули от места под туловищем
func _standSpot(torsoPos: Vector2) -> Vector2:
	lastStandShift = Vector2.ZERO
	if not normal or not (normal.shape is CapsuleShape2D):
		return torsoPos
	var space := rigid.get_world_2d().direct_space_state
	var ex: Array[RID] = [rigid.get_rid()]
	for b in rigid.find_children("*", "CollisionObject2D", true, false):
		ex.append(b.get_rid())
	var base := torsoPos
	var down := PhysicsRayQueryParameters2D.create(torsoPos + Vector2(0.0, -8.0), torsoPos + Vector2(0.0, 400.0), 1, ex)
	var floorHit := space.intersect_ray(down)
	if not floorHit.is_empty():
		base.y = float(floorHit["position"].y) - 1.0
	var c := normal.shape as CapsuleShape2D
	var sc: Vector2 = normal.global_transform.get_scale().abs()
	var cap := CapsuleShape2D.new()
	cap.radius = c.radius * sc.x
	cap.height = c.height * sc.y
	var centerOff: Vector2 = normal.global_position - rigid.global_position
	centerOff.x = 0.0
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = cap
	q.collision_mask = 1
	q.exclude = ex
	var tries: Array[Vector2] = [Vector2.ZERO]
	for dx in [40.0, 80.0, 120.0, 160.0, 220.0]:
		tries.append(Vector2(dx, 0.0))
		tries.append(Vector2(-dx, 0.0))
	for dy in [30.0, 60.0, 90.0, 120.0]:
		tries.append(Vector2(0.0, -dy))
	for t in tries:
		q.transform = Transform2D(0.0, base + t + centerOff)
		if space.intersect_shape(q, 1).is_empty():
			lastStandShift = t
			return base + t
	return base


