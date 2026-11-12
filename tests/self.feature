@kora_qa @smoke
Feature: kora_qa runner self-test
  Exercises the built-in step library end to end. Every setup is undone when
  the run ends: items, money, job, entities, time and position are restored.

  @target:2
  Scenario: Setup, observers and checks round-trip
    Sanity check for kora_qa itself. Run it after changing the step library.

    Given I am at "legion_square"
    And I run setup "picnic"
    And my job is "unemployed"
    And a "test_car" is spawned in front of me with keys
    And the vehicle is locked
    When I unlock the vehicle
    Then the vehicle should be unlocked
    When I use a "water"
    Then I should have 1 "water"
    And my cash balance should be 500
    When I go to "legion_fountain"
    Then I should be within 15 metres of "legion_fountain"
    And there should be no script errors
    Then I confirm: the steps overlay showed each step above turning green

  @target:1 @manual
  Scenario: Manual steps and notifications
    Given I am at full health
    And my armour is 50
    When I manually: open your phone and close it again
    Then I confirm: the phone opened and closed without errors
    When I wait 3 seconds
    Then I should be alive

  @target:1
  Scenario: Keys, engine, HUD and UI observers
    Given I am in the driver seat of a "test_car"
    And the vehicle engine is off
    When I turn the engine on
    Then the vehicle engine should be running
    And I should be in the driver seat
    And the HUD should be visible
    When I press the "F9" key
    Then the "kora_qa:runner" app should be open
    When I manually: close the QA runner window
    Then the minimap should be visible
    And the F8 console should show no errors
