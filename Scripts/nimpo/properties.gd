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
    "tasteIfConsumable": 0 # out of 10,
}