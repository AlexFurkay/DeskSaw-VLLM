extends Node
class_name properties
#turned this into a table cus i was manually exporting every variable

@export
var propertyTable = {
    "object": true, # this should probably remain stored as a meta
    "interest": 1,
    "danger": 0, # not used for anything yet

    "consumable": false,
    "replenishIfConsumable": 0.0,
    "moodBoostIfConsumable": 0.0,
    "tasteIfConsumable": 0, # out of 10,
    "healIfConsumable": 0.0 # HP restored on contact - bandage/syringe/medkit use this, food items leave it at 0
}

## Размер питомцев по умолчанию (команда petSize). Предметы нарисованы под
## этот размер - при другом petSize они масштабируются в ту же пропорцию,
## чтобы всё на экране соответствовало друг другу.
const BASE_PET_SCALE := 4.0

func _ready() -> void:
    var factor: float = float(gbData.settings.get("petScale", BASE_PET_SCALE)) / BASE_PET_SCALE
    if is_equal_approx(factor, 1.0):
        return
    # Сам RigidBody2D масштабировать нельзя (физика сбрасывает его масштаб) -
    # масштабируем его детей: спрайт, формы столкновений и зону наведения.
    for child in get_parent().get_children():
        if child is Node2D:
            child.scale *= factor
            child.position *= factor
