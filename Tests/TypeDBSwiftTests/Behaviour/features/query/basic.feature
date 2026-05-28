# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# NOTE: This file is NOT a verbatim copy of an upstream typedb-behaviour
# feature. It is a curated "basic query" subset authored for TypeDBSwift,
# written against the SAME step vocabulary used by the vendored
# connection/*.feature files so it runs through the same Gherkin harness.
# It exercises define/insert/match/fetch round-trips and attribute ownership
# that the connection features only touch incidentally.

#noinspection CucumberUndefinedStep
Feature: Basic Query

  Background:
    Given typedb starts
    Given connection opens with default authentication
    Given connection is open: true
    Given connection has 0 databases
    Given connection create database: typedb
    Given connection open schema transaction for database: typedb
    Given typeql schema query
      """
      define
        attribute name, value string;
        attribute age, value integer;
        entity person, owns name, owns age;
      """
    Given transaction commits

  Scenario: insert and match a single entity
    Given connection open write transaction for database: typedb
    Given typeql write query
      """
      insert $p isa person, has name "Alice", has age 30;
      """
    Given transaction commits
    Given connection open read transaction for database: typedb
    When get answers of typeql read query
      """
      match $p isa person;
      """
    Then answer size is: 1

  Scenario: insert many entities and match them all
    Given connection open write transaction for database: typedb
    Given typeql write query
      """
      insert $p isa person, has name "Alice", has age 30;
      """
    Given typeql write query
      """
      insert $p isa person, has name "Bob", has age 40;
      """
    Given typeql write query
      """
      insert $p isa person, has name "Cara", has age 50;
      """
    Given transaction commits
    Given connection open read transaction for database: typedb
    When get answers of typeql read query
      """
      match $p isa person, has name $n; select $n;
      """
    Then answer size is: 3

  Scenario: match with an attribute constraint
    Given connection open write transaction for database: typedb
    Given typeql write query
      """
      insert $p isa person, has name "Alice", has age 30;
      """
    Given typeql write query
      """
      insert $p isa person, has name "Bob", has age 40;
      """
    Given transaction commits
    Given connection open read transaction for database: typedb
    When get answers of typeql read query
      """
      match $p isa person, has age 30;
      """
    Then answer size is: 1

  Scenario: matching a nonexistent value yields no answers
    Given connection open read transaction for database: typedb
    When get answers of typeql read query
      """
      match $p isa person, has name "Nobody";
      """
    Then answer size is: 0

  Scenario: fetch documents for matched entities
    Given connection open write transaction for database: typedb
    Given typeql write query
      """
      insert $p isa person, has name "Alice", has age 30;
      """
    Given transaction commits
    Given connection open read transaction for database: typedb
    When get answers of typeql read query
      """
      match $p isa person;
      fetch { "name": $p.name, "age": $p.age };
      """
    Then answer size is: 1

  Scenario: inserting an unowned attribute fails
    Given connection open write transaction for database: typedb
    Then typeql write query; fails
      """
      insert $p isa person, has email "x@example.com";
      """
