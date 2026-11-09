extends Node
## F1-F2 «Живая физика» (идея Alex 30.10; по мотивам Casualties: Unknown - Body.HandleVisuals,
## Body.Stand, TailScript; инерция рук и головы - F1, по мотивам Gunsaw). Свой код, анимации - наши.
## Поверх анимации и IK, каждый кадр, пока персонаж на ногах:
## 1) наклон от разгона и торможения (moveSys.lean) - всё тело поворачивается вокруг таза;
## 2) присед (moveSys.crouch: приземление, вставание; и немного при наклоне) - таз ниже, ступни на месте;
## 3) отставание картинки после шага вверх (moveSys.visualOffset) - вся картинка догоняет тело;
## 4) туловище чуть поворачивается к тому, куда смотрит голова; руки при этом висят (не поворачиваются
##    вместе с туловищем), голова держит взгляд - IK рук, ног и головы пересчитывается заново;
## 5) инерция рук и головы - пружины (F1);
## 6) хвост тянется против движения (на ходу - назад и чуть вверх, в прыжке - вниз, в падении - вверх),
##    стоя - медленно возвращается к анимации; своего покачивания нет (тест Alex F1: «паттерн угадывается»);
## 7) вставание после рэгдолла: части тела перетекают из позы лёжа в позу стоя - сначала медленно,
##    потом всё быстрее (~1,1 с), из наклона в ту сторону, куда лежал, и из приседа.
## Настоящая физика частей тела стоя не включается (как и в CU) - зеркальные тела физика не умеет.
## Настройки: livePhysics (галочка, по умолчанию вкл.), livePhysicsStrength (консоль, по умолчанию 2).

const SETTING := "livePhysics"
const STRENGTH_SETTING := "livePhysicsStrength"
const DEFAULT_STRENGTH := 2.0 # Alex (тест F1): «live_physics_strength 2 выглядит неплохо»
const TAIL_STRENGTH_OFFSET := 1.5 # Alex: «на хвост -1,5 к общей силе»: хвост живой при силе выше 1,5
## Инерция рук и головы - от движения ВСЕГО тела (капсула moveSys.rigid), а не от положения костей:
## анимация меняет скорость костей скачками на ключевых кадрах (стенд F1: дрожь до 24 px за кадр).
const MAX_ACCEL := 4000.0 # px/с² - сильнее не считаем (рывок, перенос тела при вставании)
const ACCEL_SMOOTH := 0.10 # с - сглаживание ускорения
const ACCEL_DEADZONE := 300.0 # px/с² - меньше не считается

## Пружины (F1). F2.1 (тест Alex F2: «руки смешно и неестественно трясутся», «предплечье выгибается
## в обратную сторону», «как маятники», «замедлить в 2 раза»): руки - вдвое медленнее (1,1-1,3 Гц вместо
## 2,2-2,6) и почти без перекачки (затухание 0,55-0,6 вместо 0,3); предплечье только сгибается в локте.
# путь кости от Skeleton2D, частота (Гц), затухание (доля от критического), предел (рад), сила инерции,
# это предплечье (локоть не разгибается дальше прямой)
const SPRINGS := [
	["hip/back/head", 2.4, 0.60, 0.22, 0.5, false], # F2.1: было 3,2 Гц / 0,45 / 1,4 - при новой ходьбе до 11°; теперь ~6°
	["hip/back/fArm", 1.1, 0.55, 0.55, 0.20, false],
	["hip/back/fArm/fLArm", 1.3, 0.60, 0.35, 0.12, true],
	["hip/back/BArm", 1.1, 0.55, 0.55, 0.20, false],
	["hip/back/BArm/BLArm", 1.3, 0.60, 0.35, 0.12, true],
]

## CU (1 единица CU ~ 53 px: рост персонажа CU ~3,6 ед., у нас ~190 px).
const LEAN_DIP := 0.8 # px приседа на градус наклона (CU: down * |accelRot * 0,015| ед.)
const ELBOW_RETURN := 3.0 # рад/с - так быстро предплечье возвращается к позе IK, если оказалось «не туда»
const FOOT_CLEARANCE := 18.0 # px (при масштабе 4) - цель ноги не ниже низа капсулы минус столько (стоя ~12-18; при 13 ступни были на 2-4 px ниже пола)
const CROUCH_IN_SPEED := 300.0 # px/с - присед нарастает плавно (~0,1 с), а не за один кадр (рывок рук и тела при приземлении)
const ARM_MAX_SPEED := 8.0 # рад/с - быстрее рука за кадр не поворачивается (любой рывок IK или пружины - в 2-3 кадра)
const OFFSET_RATE := 8.0 # CU: visualBodyOffset = Lerp(.., 0, dt * 8)
const CROUCH_RATE := 6.0 # CU: crouchAmount = Lerp(.., 0, dt * 6)
const TORSO_LOOK := 0.207 # CU: туловище - угол взгляда * 0,6 * 0,3 = 0,18; F2.1 (Alex: «практически незаметно, +15 %») - 0,207
const TORSO_RATE := 4.0 # CU: torsoLookSmooth = Lerp(.., .., dt * 4)
const TORSO_MAX_LOOK := PI / 2.0 # угол взгляда больше 90° не считаем
const TAIL_UNIT := 53.0 # px в единице CU
const TAIL_RATE := 0.14 # CU: LerpAngle(.., .., dt * |v| * 0,14)
const TAIL_IDLE_RATE := 0.78 # CU: стоя - LerpAngle(.., .., dt * 0,78)
const TAIL_MOVING := 75.0 # px/с - быстрее этого хвост тянется за движением (CU: 1,4 ед./с)
const TAIL_MAX := 1.3962634 # 80° - не дальше от «прямо назад» (CU: Clamp(b, -80, 80))
const TAIL_DOWN := 0.1 # CU: (направление движения + вниз * 0,1)
## F2.1 (тест Alex F2: «паттерн не меняется при смене toggle_live_physics»): стоя хвост качает сама анимация
## покоя - ровно ±2,5° раз в секунду. С живой физикой вместо этого - неровно: к случайной цели за случайное
## время (1,2-3,5 с), изредка взмах побольше и побыстрее; вокруг среднего положения из анимации.
const TAIL_IDLE_SMALL := 0.07 # рад (~4°)
const TAIL_IDLE_SWISH := 0.20 # рад (~11°)
const TAIL_SWISH_CHANCE := 0.15
const STAND_RATE := 0.875 # CU: standLerpTime += dt * 2,5 * 0,35 - вставание ~1,1 с
const STAND_PULL := 14.0 # CU: Lerp(текущее, цель, standLerpTime * dt * 40 * 0,35)
const STAND_LEAN := 0.6 # CU: accelRot = угол туловища * 0,6
const STAND_LEAN_MAX := 60.0 # градусов
const STAND_CROUCH := 70.0 # px - встаёт из глубокого приседа (CU: crouchAmount = 1); глубже, чем ноги позволяют, не будет (LEG_MIN_REACH)
## F2.3 (Alex: «в CU сначала корпус принимает вертикальное положение, потом встают ноги»): первую часть
## вставания присед держится - тело выпрямляется на согнутых ногах, потом ноги разгибаются.
const STAND_HOLD := 0.55 # доля вставания, пока присед держится
## F2.3 (тест Alex F2.2, Screenshot_5: «при приседе ноги багаются, почти телепортируются»): таз не опускается
## так низко, чтобы ступня оказалась ближе к бедру, чем эта доля длины ноги - иначе IK ноги перескакивает.
const LEG_MIN_REACH := 0.45

var moveSys = null
var springs: Array = [] # {bone, k, c, max, gain, d, w, base, written, len}
var blend: Array = [] # по порядку от корня: {body, rt, parent (индекс в blend или -1), cur, g}
var blending := false
var limbs: Array = [] # {body, rt, bone, parent (индекс или -1), depth} - все части тела с RemoteTransform
var _snap: Dictionary = {} # body -> Transform2D: поза в последнем кадре рэгдолла (до переноса тела)
var _standLerp := 1.0
var _wasLive := false
var _pv := Vector2.INF # скорость тела в прошлом шаге физики
var bodyAcc := Vector2.ZERO # сглаженное ускорение тела, px/с² (глобальные)

# кости и IK
var _hip: Bone2D = null
var _back: Bone2D = null
var _tail: Bone2D = null
var _ikLegs: Array = [] # SoupTwoBoneIK ног
var _feet: Array = [] # Bone2D ступней (по порядку _ikLegs) - при приседе держат свой наклон
var _footBase: Array = [] # их поворот без нас (анимация ступни не трогает - наша запись иначе копилась бы)
var _footWritten: Array = []
var _footFlat: Array = [] # угол ступни в кадре скелета, когда стоит спокойно (среднее) - так она стоит на полу
var _ikArms: Array = [] # [SoupTwoBoneIK, плечо (Bone2D)]
var _lookAt = null # SoupLookAt головы
# свои записи в кости (если кость с прошлого кадра никто не трогал - основа прежняя, а не наша запись)
var _hipBasePos := Vector2.ZERO
var _hipBaseRot := 0.0
var _hipWrittenPos := Vector2.INF
var _hipWrittenRot := INF
var _backBase := 0.0
var _backWritten := INF
var _tailBase := 0.0
var _tailWritten := INF
var _torso := 0.0 # рад, туловище к взгляду (сглаженное, в кадре скелета)
var _crouchShown := 0.0 # px, присед на картинке (нарастает плавно)
var _tailOff := 0.0 # рад, хвост от анимации
var _tailMean := INF # рад, среднее положение хвоста в анимации (плавно, за ~2 с)
var _tailIdle := 0.0 # рад, неровное движение стоя
var _tailIdleFrom := 0.0
var _tailIdleTo := 0.0
var _tailIdleT := 1.0
var _tailIdleDur := 1.0
var _tailIdleW := 0.0 # 0 - хвост как в анимации, 1 - своё движение стоя

# для стенда
var lastBlendMirror := 1.0 # каким встал (1 - как скелет без зеркала, -1 - зеркально)
var lastLean := 0.0 # градусов, наклон в этом кадре
var lastCrouch := 0.0 # px, присед в этом кадре
var lastTorso := 0.0 # градусов
var lastTail := 0.0 # градусов
var lastBlendTime := 0.0 # с, сколько длилось последнее вставание
var _blendT := 0.0


func enabled() -> bool:
	return bool(gbData.settings.get(SETTING, true))


func strength() -> float:
	return clampf(float(gbData.settings.get(STRENGTH_SETTING, DEFAULT_STRENGTH)), 0.0, 3.0)


## Во сколько раз живее, чем при силе 2 (F2.1, тест Alex F2: «сила 3 и 1 - по ощущениям так же»; было
## сила/2, то есть 3 - лишь в 1,5 раза): 0 - нет, 1 - вполовину, 2 - как задумано, 3 - вдвое сильнее.
func _k(st: float) -> float:
	return st / 2.0 if st <= 2.0 else st - 1.0


func setup(ms) -> void:
	moveSys = ms
	process_priority = 10 # после AnimationPlayer и IK (SoupMod) - иначе они перезапишут наши правки
	var sk: Node = moveSys.skeleton
	for spec in SPRINGS:
		var b := sk.get_node_or_null(spec[0]) as Bone2D
		if b == null:
			continue
		var w := TAU * float(spec[1])
		var boneLen: float = b.get_length() if b.get_length() > 1.0 else 12.0
		var elbow: bool = spec[5]
		var straight := 0.0
		if elbow and b.get_parent() is Bone2D:
			straight = (b.get_parent() as Bone2D).get_bone_angle() - b.get_bone_angle() # локоть прямой
		springs.append({"bone": b, "k": w * w, "c": 2.0 * float(spec[2]) * w, "max": float(spec[3]),
			"gain": float(spec[4]), "d": 0.0, "w": 0.0, "base": b.rotation, "written": INF, "len": boneLen,
			"elbow": elbow, "straight": straight, "flex": 0.0, "prevA": INF})
	_hip = sk.get_node_or_null("hip") as Bone2D
	_back = sk.get_node_or_null("hip/back") as Bone2D
	_tail = sk.get_node_or_null("hip/Tail") as Bone2D
	for n in sk.find_children("*", "", true, false):
		if n is SoupTwoBoneIK:
			var j1: Bone2D = n.joint_one_bone_node
			if j1 == null or n.target_node == null:
				continue
			if j1.get_parent() == _hip:
				_ikLegs.append(n)
				var j2: Bone2D = n.joint_two_bone_node
				var fbone: Bone2D = j2.get_node_or_null("Foot") as Bone2D if j2 != null else null
				_feet.append(fbone)
				_footBase.append(fbone.rotation if fbone != null else 0.0)
				_footWritten.append(INF)
				_footFlat.append(INF)
			else:
				_ikArms.append([n, j1])
		elif n is SoupLookAt and n.target_node != null:
			_lookAt = n
	_mapLimbs()


## Части тела по иерархии костей: RemoteTransform кости -> тело; родитель - тело родительской кости.
func _mapLimbs() -> void:
	limbs.clear()
	var byBone := {}
	for rt in moveSys.skeleton.find_children("*", "RemoteTransform2D", true, false):
		var body := rt.get_node_or_null(rt.remote_path) as RigidBody2D
		var bone := rt.get_parent() as Bone2D
		if body == null or bone == null:
			continue
		byBone[bone] = limbs.size()
		limbs.append({"body": body, "rt": rt, "bone": bone, "parent": -1, "depth": 0})
	for e in limbs:
		var pb = (e["bone"] as Bone2D).get_parent()
		var depth := 0
		while pb is Bone2D:
			depth += 1
			if e["parent"] == -1 and byBone.has(pb):
				e["parent"] = byBone[pb]
			pb = pb.get_parent()
		e["depth"] = depth


## Персонаж обмяк (рэгдолл): всё живое - с нуля.
func onRagdoll() -> void:
	blending = false
	blend.clear()
	_snap.clear()
	_releaseBody()


## Конец рэгдолла: части тела заморожены, но их RemoteTransform ещё выключены - тянем тела
## от позы лёжа к позе анимации, потом включаем RemoteTransform.
## Тест Alex F1: 1) перс телепортировался «до 15 голов» - поза «откуда» бралась уже после переноса
## «ходячего» тела к туловищу (части тела переезжают вместе с ним); теперь - из последнего кадра
## рэгдолла. 2) «смешно переворачивается, принимая вертикальную форму» - лёжа части тела зеркальные
## (персонаж смотрел влево), а поза стоя - нет, и переход шёл через сплющивание; теперь скелет
## встаёт с тем же зеркалом, что и тело лёжа, и части тела тянутся каждая относительно родителя.
func startBlend(rts: Array) -> void:
	blend.clear()
	var want := {}
	for rt in rts:
		want[rt] = true
	var rootFrom := Transform2D()
	var found := false
	for e in limbs:
		if e["parent"] == -1 and want.has(e["rt"]):
			rootFrom = _snap.get(e["body"], (e["body"] as Node2D).global_transform)
			found = true
			break
	if found:
		var s := signf(rootFrom.determinant())
		if s != 0.0:
			moveSys.skelparent.scale.x = s
			moveSys.flip = s < 0.0
			lastBlendMirror = s
		# CU Stand: встаёт из наклона в ту сторону, куда лежал (угол туловища * 0,6), и из приседа.
		# «Вверх» туловища - минус его ось y (зеркало по x её не трогает).
		var up := -rootFrom.y
		if up.length() > 0.001:
			var tilt := rad_to_deg(atan2(up.x, -up.y))
			moveSys.lean = clampf(tilt * STAND_LEAN, -STAND_LEAN_MAX, STAND_LEAN_MAX)
		moveSys.crouch = STAND_CROUCH
	# порядок: сначала корень, потом дети
	var order: Array = []
	for i in limbs.size():
		if want.has(limbs[i]["rt"]):
			order.append(i)
	order.sort_custom(func(a, b): return int(limbs[a]["depth"]) < int(limbs[b]["depth"]))
	var slot := {}
	for i in order:
		var e: Dictionary = limbs[i]
		var from: Transform2D = _snap.get(e["body"], (e["body"] as Node2D).global_transform)
		var p: int = e["parent"]
		var cur := from
		if p != -1 and slot.has(p):
			var pf: Transform2D = _snap.get(limbs[p]["body"], (limbs[p]["body"] as Node2D).global_transform)
			cur = pf.affine_inverse() * from
		slot[i] = blend.size()
		blend.append({"body": e["body"], "rt": e["rt"], "parent": slot.get(p, -1) if p != -1 else -1,
			"cur": cur, "g": from})
	_standLerp = 0.0
	_blendT = 0.0
	blending = not blend.is_empty()
	# первую позу - сразу: перенос «ходячего» тела бывает уже после нашего _process в этом кадре,
	# и кадр рисовался бы с частями тела, уехавшими вместе с ним (стенд F2: центр тела +200 px за кадр)
	for e in blend:
		if is_instance_valid(e["body"]):
			(e["body"] as Node2D).global_transform = e["g"]
	_snap.clear()
	_resetSprings()


func _finishBlend() -> void:
	for e in blend:
		var rt: RemoteTransform2D = e["rt"]
		rt.update_position = true
		rt.update_rotation = true
		rt.update_scale = true
	blend.clear()
	blending = false
	lastBlendTime = _blendT


func _resetSprings() -> void:
	for s in springs:
		s["d"] = 0.0
		s["w"] = 0.0
		s["written"] = INF
		s["prevA"] = INF
	_pv = Vector2.INF
	bodyAcc = Vector2.ZERO


## Ускорение тела - по шагам физики (скорость капсулы меняется только в них; в кадрах между
## шагами она стоит, и разность по кадрам была бы то нулём, то всплеском).
func _physics_process(delta: float) -> void:
	if moveSys == null or delta <= 0.0 or not moveSys.notragdolled or blending:
		_pv = Vector2.INF
		bodyAcc = Vector2.ZERO
		return
	var v: Vector2 = moveSys.rigid.linear_velocity
	if _pv != Vector2.INF:
		var a := (v - _pv) / delta
		var al := a.length()
		if al > MAX_ACCEL:
			a = a * (MAX_ACCEL / al)
		# мёртвая зона: тело, стоящее на полу, чуть подпрыгивает от шага физики - это не движение
		al = a.length()
		a = a * (maxf(0.0, al - ACCEL_DEADZONE) / al) if al > 0.0 else Vector2.ZERO
		bodyAcc = bodyAcc.lerp(a, clampf(delta / ACCEL_SMOOTH, 0.0, 1.0))
	_pv = v


func _process(delta: float) -> void:
	if moveSys == null or delta <= 0.0:
		return
	if not moveSys.notragdolled:
		# поза лёжа - каждый кадр: из неё начнётся вставание (до переноса «ходячего» тела)
		for e in limbs:
			_snap[e["body"]] = moveSys.visualXf(e["body"]) # F2.2: зеркальная лёжа - как выглядит
		if _wasLive:
			_releaseBody()
		_wasLive = false
		return
	var live: bool = enabled()
	var st := strength()
	if blending:
		_blendT += delta
		_applyBody(delta, st) # цель вставания - уже с наклоном и приседом
		_stepBlend(delta)
		_wasLive = true
		return
	if not live:
		if _wasLive:
			_releaseBody()
		_wasLive = false
		return
	_wasLive = true
	_applyBody(delta, st)
	var sdt := minf(delta, 1.0 / 30.0) # игра просела до 10 кадров/с - пружину большим шагом «разнесло» бы
	for s in springs:
		_stepSpring(s, sdt, st)
	_limitArms(delta)
	_stepTail(delta, st)


## F2.1 (стенд: кисть иногда прыгала на 8 px за кадр сразу после приземления): рука в кадре скелета
## поворачивается не быстрее ARM_MAX_SPEED - откуда бы ни взялся скачок (IK, пружина), он растянется.
func _limitArms(delta: float) -> void:
	var skInv := (moveSys.skeleton as Node2D).global_transform.affine_inverse()
	var lim := ARM_MAX_SPEED * delta
	for s in springs:
		var b: Bone2D = s["bone"]
		if not is_instance_valid(b) or b.name == "head":
			continue
		var a := (skInv * b.global_transform).get_rotation()
		var pa := float(s["prevA"])
		if pa != INF:
			var da := wrapf(a - pa, -PI, PI)
			if absf(da) > lim:
				b.rotation -= da - signf(da) * lim
				s["written"] = b.rotation
				a = pa + signf(da) * lim
		s["prevA"] = a


## CU HandleVisuals: наклон, присед, отставание картинки, туловище к взгляду, висящие руки, взгляд головы.
func _applyBody(delta: float, st: float) -> void:
	var ms = moveSys
	var k := _k(st) # сила 2 - как в CU, 0 - без наклона и приседа, 3 - вдвое сильнее
	# затухание (CU: visualBodyOffset - dt * 8, crouchAmount - dt * 6); вставая - сначала присед держится
	var vo: Vector2 = ms.visualOffset
	ms.visualOffset = vo.lerp(Vector2.ZERO, clampf(delta * OFFSET_RATE, 0.0, 1.0))
	if not (blending and _standLerp < STAND_HOLD):
		ms.crouch = lerpf(float(ms.crouch), 0.0, clampf(delta * CROUCH_RATE, 0.0, 1.0))
	if _hip == null:
		return
	var skXf: Transform2D = (ms.skeleton as Node2D).global_transform
	var skInv := skXf.affine_inverse()
	var mirror := signf(skXf.determinant())
	if mirror == 0.0:
		mirror = 1.0
	var resting: bool = ms.currstate == ms.states.resting
	# основа таза - то, что поставила анимация (если с нашей прошлой записи его никто не трогал -
	# прежняя основа: анимация могла закончиться, и наши правки копились бы)
	if _hip.position.distance_squared_to(_hipWrittenPos) > 1e-8:
		_hipBasePos = _hip.position
	if absf(_hip.rotation - _hipWrittenRot) > 1e-6:
		_hipBaseRot = _hip.rotation
	_hip.position = _hipBasePos
	_hip.rotation = _hipBaseRot
	for i in _feet.size():
		var fb0: Bone2D = _feet[i]
		if fb0 == null:
			continue
		if absf(fb0.rotation - float(_footWritten[i])) <= 1e-6:
			fb0.rotation = float(_footBase[i]) # прошлая наша запись - назад к основе
		else:
			_footBase[i] = fb0.rotation
		_footWritten[i] = INF
	# туловище к взгляду - до правок таза (CU torsoLookSmooth); сидя и лёжа - нет
	var torsoWant := 0.0
	if not resting and _back != null and ms.headIk != null and ms.defheadnose != null:
		var c: Vector2 = skInv * _back.global_position
		var look: Vector2 = skInv * (ms.headIk as Node2D).global_position - c
		var rest: Vector2 = skInv * (ms.defheadnose as Node2D).global_position - c
		if look.x > 1.0 and rest.length() > 1.0:
			torsoWant = clampf(wrapf(look.angle() - rest.angle(), -PI, PI), -TORSO_MAX_LOOK, TORSO_MAX_LOOK) * TORSO_LOOK * k
	_torso = lerpf(_torso, torsoWant, clampf(delta * TORSO_RATE, 0.0, 1.0))
	# руки до правок: плечо и цель IK - руки будут висеть, а не поворачиваться с туловищем
	var armsBefore: Array = []
	for a in _ikArms:
		armsBefore.append([(a[1] as Node2D).global_position, (a[0].target_node as Node2D).global_position])
	# 1) наклон: всё тело - вокруг таза (CU: RotateAround(limbs[2], accelRot)); ступни - вместе с ним
	# F2.5 (чек-лист Alex, Screenshot_3: персы сидят чуть под полом): сидя и лёжа поза - только из анимации,
	# присед после приземления и наклон от разгона таз больше не опускают
	var leanDeg: float = 0.0 if resting else float(ms.lean) * k
	_hip.rotation = _hipBaseRot + deg_to_rad(leanDeg) * mirror
	var feet: Array = []
	var grounded: bool = ms.floorRay.is_colliding()
	var calm: bool = grounded and not resting and ms.currstate == ms.states.idle and float(ms.crouch) < 0.5 and absf(float(ms.lean)) < 1.0
	for i in _ikLegs.size():
		feet.append((_ikLegs[i].target_node as Node2D).global_position)
		var fb1: Bone2D = _feet[i]
		if fb1 != null and calm:
			var a1 := (skInv * fb1.global_transform).get_rotation()
			_footFlat[i] = a1 if float(_footFlat[i]) == INF else lerp_angle(float(_footFlat[i]), a1, clampf(delta * 2.0, 0.0, 1.0))
	# 2) присед (таз ниже, ступни на месте) и отставание картинки (вся картинка)
	var cWant := float(ms.crouch)
	_crouchShown = move_toward(_crouchShown, cWant, CROUCH_IN_SPEED * delta) if cWant > _crouchShown else cWant
	var crouchPx: float = 0.0 if resting else (_crouchShown + absf(float(ms.lean)) * LEAN_DIP) * k
	var off: Vector2 = ms.visualOffset
	# ступни не ниже пола: в прыжке и падении цели ног анимации опущены (ноги вытянуты), и глубокий
	# присед давал ногам их достать - ступни уходили в пол на 6 px (стенд F2.1)
	var skScale := absf(skXf.get_scale().y)
	var floorY: float = (ms.rigid as Node2D).global_position.y + off.y - FOOT_CLEARANCE * skScale / 4.0
	var legWant: Array = []
	for i in _ikLegs.size():
		var w0: Vector2 = feet[i] + off
		w0.y = minf(w0.y, floorY)
		legWant.append(w0)
		# таз не ниже, чем позволяет нога (иначе IK перескакивает на другое решение - «ноги багаются»)
		var j1: Bone2D = _ikLegs[i].joint_one_bone_node
		var j2: Bone2D = _ikLegs[i].joint_two_bone_node
		if j1 != null and j2 != null:
			var minD: float = (j1.get_length() + j2.get_length()) * skScale * LEG_MIN_REACH
			var hp: Vector2 = j1.global_position + off
			var dx: float = w0.x - hp.x
			var room: float = (w0.y - hp.y) - sqrt(maxf(minD * minD - dx * dx, 0.0))
			crouchPx = minf(crouchPx, maxf(room, 0.0))
	lastCrouch = crouchPx
	_hip.position = _hipBasePos + skInv.basis_xform(off + Vector2(0.0, crouchPx))
	if crouchPx > 0.01:
		for i in _ikLegs.size():
			var tgt: Node2D = _ikLegs[i].target_node
			var keep := tgt.position
			var want: Vector2 = legWant[i]
			tgt.global_position = want
			_ikLegs[i]._process_loop(0.0)
			tgt.position = keep
			# приземлился или встаёт (глубокий присед) - ступня стоит ровно, как стоя: иначе она остаётся в
			# наклоне позы падения (носок вниз) и уходит в пол (стенд F2.1: до 6 px ниже пола при приземлении)
			var fb2: Bone2D = _feet[i]
			var flat := float(_footFlat[i])
			if fb2 != null and grounded and flat != INF and _crouchShown > 1.0:
				var wt := clampf(_crouchShown * k / 20.0, 0.0, 1.0)
				var a2 := (skInv * fb2.global_transform).get_rotation()
				fb2.rotation += wrapf(flat - a2, -PI, PI) * wt
				_footWritten[i] = fb2.rotation
	_hipWrittenPos = _hip.position
	_hipWrittenRot = _hip.rotation
	# 3) туловище (кость back анимация не трогает)
	if _back != null:
		if absf(_back.rotation - _backWritten) > 1e-6:
			_backBase = _back.rotation
		_back.rotation = _backBase + _torso
		_backWritten = _back.rotation
	# 4) руки висят: цель IK едет вместе с плечом, но не поворачивается (CU: руки - обратно на -(наклон + туловище))
	for i in _ikArms.size():
		var ik = _ikArms[i][0]
		var tgt: Node2D = ik.target_node
		var keep := tgt.position
		tgt.global_position = armsBefore[i][1] + ((_ikArms[i][1] as Node2D).global_position - armsBefore[i][0])
		ik._process_loop(0.0)
		tgt.position = keep
	# 5) голова держит взгляд
	if _lookAt != null:
		_lookAt._process_loop(0.0)
	lastLean = leanDeg
	lastTorso = rad_to_deg(_torso)


## Выключили «живую физику» или упал: вернуть таз, туловище и хвост к анимации, всё живое - с нуля.
func _releaseBody() -> void:
	if _hip != null:
		if _hip.position.distance_squared_to(_hipWrittenPos) <= 1e-8:
			_hip.position = _hipBasePos
		if absf(_hip.rotation - _hipWrittenRot) <= 1e-6:
			_hip.rotation = _hipBaseRot
	if _back != null and absf(_back.rotation - _backWritten) <= 1e-6:
		_back.rotation = _backBase
	if _tail != null and absf(_tail.rotation - _tailWritten) <= 1e-6:
		_tail.rotation = _tailBase
	for i in _feet.size():
		var fb3: Bone2D = _feet[i]
		if fb3 != null and absf(fb3.rotation - float(_footWritten[i])) <= 1e-6:
			fb3.rotation = float(_footBase[i])
		_footWritten[i] = INF
	_hipWrittenPos = Vector2.INF
	_hipWrittenRot = INF
	_backWritten = INF
	_tailWritten = INF
	_torso = 0.0
	_crouchShown = 0.0
	_tailOff = 0.0
	_tailIdleW = 0.0
	_tailMean = INF
	for s in springs:
		var b: Bone2D = s["bone"]
		if is_instance_valid(b) and absf(b.rotation - float(s["written"])) < 1e-5:
			b.rotation = float(s["base"])
	_resetSprings()
	if moveSys != null:
		moveSys.lean = 0.0
		moveSys.crouch = 0.0
		moveSys.visualOffset = Vector2.ZERO


## Вставание (CU Stand + HandleVisuals): каждая часть тела каждый кадр подтягивается к позе стоя на
## долю standLerp * dt * 14, а standLerp растёт на 0,875 в секунду - сначала медленно, потом быстрее.
## Корень - в мире (капсулу после переноса выталкивает из пола - тело за ней не прыгает), остальные -
## относительно родителя.
func _stepBlend(delta: float) -> void:
	_standLerp = minf(1.0, _standLerp + delta * STAND_RATE)
	var a := clampf(_standLerp * delta * STAND_PULL, 0.0, 1.0)
	for e in blend:
		var body: Node2D = e["body"]
		if not is_instance_valid(body):
			continue
		var to: Transform2D = (e["rt"] as RemoteTransform2D).global_transform
		var p: int = e["parent"]
		var cur: Transform2D = e["cur"]
		var g: Transform2D
		if p == -1:
			cur = cur.interpolate_with(to, a)
			g = cur
		else:
			var pe: Dictionary = blend[p]
			var pTo: Transform2D = (pe["rt"] as RemoteTransform2D).global_transform
			var toLocal := pTo.affine_inverse() * to
			if signf(cur.determinant()) != signf(toLocal.determinant()):
				# зеркало не совпало (так не должно быть) - без сплющивания, просто как у цели
				cur = Transform2D(cur.get_rotation(), toLocal.get_scale(), 0.0, cur.origin)
			cur = cur.interpolate_with(toLocal, a)
			g = (pe["g"] as Transform2D) * cur
		e["cur"] = cur
		e["g"] = g
		body.global_transform = g
	if _standLerp >= 1.0:
		_finishBlend()


## Хвост (CU TailScript): на ходу - против движения (+ чуть вверх), не дальше 80° от «прямо назад»,
## подтягивается тем быстрее, чем быстрее тело; стоя - медленно возвращается к анимации.
func _stepTail(delta: float, st: float) -> void:
	if _tail == null or _hip == null:
		return
	var r := _tail.rotation
	var anim: float = _tailBase if absf(r - _tailWritten) < 1e-6 else r
	var w := clampf((st - TAIL_STRENGTH_OFFSET) * 2.0, 0.0, 1.0) # сила 2 - хвост как в CU; 1,5 и меньше - только анимация
	var v: Vector2 = moveSys.rigid.linear_velocity
	var speed := v.length()
	var resting: bool = moveSys.currstate == moveSys.states.resting
	# стоя - своё неровное движение вместо ровного качания анимации
	_tailMean = anim if _tailMean == INF else lerpf(_tailMean, anim, clampf(delta / 2.0, 0.0, 1.0))
	_tailIdleT += delta
	if _tailIdleT >= _tailIdleDur:
		_tailIdleFrom = _tailIdle
		if randf() < TAIL_SWISH_CHANCE:
			_tailIdleTo = randf_range(0.6, 1.0) * TAIL_IDLE_SWISH * (1.0 if randf() < 0.5 else -1.0)
			_tailIdleDur = randf_range(0.5, 0.9)
		else:
			_tailIdleTo = randf_range(-1.0, 1.0) * TAIL_IDLE_SMALL
			_tailIdleDur = randf_range(1.2, 3.5)
		_tailIdleT = 0.0
	var u := clampf(_tailIdleT / _tailIdleDur, 0.0, 1.0)
	_tailIdle = lerpf(_tailIdleFrom, _tailIdleTo, u * u * (3.0 - 2.0 * u))
	_tailIdleW = move_toward(_tailIdleW, 1.0 if (speed <= TAIL_MOVING and not resting and w > 0.0) else 0.0, delta * 2.0)
	var baseRot := lerpf(anim, _tailMean + _tailIdle * w * maxf(1.0, _k(st)), _tailIdleW)
	var want := 0.0
	var rate := TAIL_IDLE_RATE
	if speed > TAIL_MOVING and not resting and w > 0.0:
		# в кадре скелета персонаж всегда смотрит в +x, «назад» - это -x
		var m := (moveSys.skeleton as Node2D).global_transform.affine_inverse().basis_xform(v).normalized()
		var tip := -(m + Vector2(0.0, TAIL_DOWN)).normalized()
		var a := clampf(wrapf(tip.angle() - PI, -PI, PI), -TAIL_MAX, TAIL_MAX)
		var animTip := _hip.rotation + baseRot + _tail.get_bone_angle()
		want = wrapf(PI + a - animTip, -PI, PI) * w
		rate = speed / TAIL_UNIT * TAIL_RATE
	_tailOff = lerp_angle(_tailOff, want, clampf(delta * rate, 0.0, 1.0))
	_tail.rotation = baseRot + _tailOff
	_tailBase = anim
	_tailWritten = _tail.rotation
	lastTail = rad_to_deg(_tailOff)


func _stepSpring(s: Dictionary, dt: float, st: float) -> void:
	var b: Bone2D = s["bone"]
	if not is_instance_valid(b):
		return
	# основа - то, что поставили анимация и IK в этом кадре; если кость никто не трогал
	# с нашей прошлой записи - прошлая основа (иначе смещение копилось бы)
	var r := b.rotation
	var base: float = float(s["base"]) if absf(r - float(s["written"])) < 1e-5 else r
	# ускорение тела - в пространстве родителя кости (там же и угол кости, зеркало учтено)
	var parent := b.get_parent() as Node2D
	var aLocal := Vector2.ZERO
	if parent:
		# affine_inverse, не basis_xform_inv: тот не делит на масштаб (персонажи увеличены в 4 раза -
		# ускорение выходило в 16 раз больше, руки упирались в предел; стенд F1, 2-й прогон)
		aLocal = parent.global_transform.affine_inverse().basis_xform(bodyAcc)
	# инерция: тело ускоряется - конечность отстаёт (сила -m*a на плече len)
	var dir := Vector2.RIGHT.rotated(base + b.get_bone_angle())
	var kk := _k(st)
	var alpha := -(dir.x * aLocal.y - dir.y * aLocal.x) / float(s["len"]) * float(s["gain"]) * 2.0 * kk
	var d := float(s["d"])
	var w := float(s["w"])
	w += (-float(s["k"]) * d - float(s["c"]) * w + alpha) * dt
	d += w * dt
	var m := float(s["max"]) * maxf(1.0, kk)
	if absf(d) > m:
		d = clampf(d, -m, m)
		w = 0.0
	if s["elbow"]:
		# локоть: пружина может только сильнее согнуть руку (туда, куда её согнул IK), а разгибать дальше
		# позы IK - нет. Всё непрерывно: мгновенный сброс в ноль дёргал кисть на 8 px за кадр (стенд F2.1),
		# когда IK на кадр менял сторону сгиба.
		var e0 := wrapf(base - float(s["straight"]), -PI, PI)
		var fs := float(s["flex"])
		if absf(e0) > 0.15 or (fs == 0.0 and absf(e0) > 0.08):
			fs = signf(e0) # сторона сгиба - только по уверенному сгибу (не дёргается у прямой руки)
			s["flex"] = fs
		var dPrev := float(s["d"])
		if fs == 0.0:
			d = move_toward(dPrev, 0.0, ELBOW_RETURN * dt) # сгиб неизвестен - плавно к позе IK
			w = 0.0
		elif d * fs < 0.0:
			if dPrev * fs >= 0.0:
				d = 0.0 # на этом шаге дошла до позы IK - остановилась (dPrev и так около нуля)
			else:
				d = move_toward(dPrev, 0.0, ELBOW_RETURN * dt) # IK сменил сторону сгиба - плавно к его позе
			w = 0.0
	if is_nan(d) or is_nan(w):
		d = 0.0
		w = 0.0
	s["d"] = d
	s["w"] = w
	s["base"] = base
	b.rotation = base + d
	s["written"] = b.rotation
