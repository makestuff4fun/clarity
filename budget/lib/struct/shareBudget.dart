import 'dart:async';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:drift/drift.dart' hide Query, Column;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:budget/struct/backend/syncBackend.dart';

/// Shared budgets are only reachable once a [ShareBackend] is registered and a
/// user is signed in. Until then this behaves exactly like being offline: the
/// app queues outgoing changes instead of failing.
bool get _shareAvailable => shareBackend.currentUserEmail != null;

Future<bool> shareBudget(Budget? budgetToShare, context) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (budgetToShare == null) {
    return false;
  }
  if (!_shareAvailable) {
    return false;
  }
  Map<String, dynamic> budgetEntry = {
    "name": budgetToShare.name,
    "amount": budgetToShare.amount,
    "colour": budgetToShare.colour,
    "startDate": budgetToShare.startDate,
    "endDate": budgetToShare.endDate,
    "periodLength": budgetToShare.periodLength,
    "reoccurrence": enumRecurrence[budgetToShare.reoccurrence],
    "members": [],
    "dateShared": DateTime.now(),
    "owner": shareBackend.currentUserId,
    "ownerEmail": shareBackend.currentUserEmail,
    "dateUpdated": DateTime.now(),
  };

  String sharedKey = await shareBackend.createSharedBudget(budgetEntry);

  await database.createOrUpdateBudget(
    budgetToShare.copyWith(
      sharedKey: Value(sharedKey),
      sharedOwnerMember: Value(SharedOwnerMember.owner),
      sharedDateUpdated: Value(DateTime.now()),
      sharedMembers: Value([shareBackend.currentUserEmail!]),
      categoryFks: Value(null),
      budgetTransactionFilters: Value(null),
      memberTransactionFilters: Value(null),
    ),
    updateSharedEntry: false,
  );

  openSnackbar(SnackbarMessage(title: "Shared Budget"));
  loadingProgressKey.currentState?.setProgressPercentage(0);
  return true;
}

Future<bool> removedSharedFromBudget(Budget sharedBudget,
    {bool removeFromServer = true}) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (removeFromServer)
    try {
      if (!_shareAvailable) {
        return false;
      }
      await shareBackend.deleteSharedBudget(sharedBudget.sharedKey!);
    } catch (e) {
      print(e.toString());
    }

  List<Transaction> transactionsFromBudget = await database
      .getAllTransactionsBelongingToSharedBudget(sharedBudget.budgetPk);
  List<Transaction> allTransactionsToUpdate = [];
  for (Transaction transactionFromBudget in transactionsFromBudget) {
    allTransactionsToUpdate.add(transactionFromBudget.copyWith(
      sharedKey: Value(null),
      sharedDateUpdated: Value(null),
      sharedStatus: Value(null),
    ));
  }
  await database.updateBatchTransactionsOnly(allTransactionsToUpdate);
  await database.createOrUpdateBudget(
    sharedBudget.copyWith(
      sharedDateUpdated: Value(null),
      sharedKey: Value(null),
      sharedOwnerMember: Value(null),
      sharedMembers: Value(null),
      budgetTransactionFilters: Value(null),
      memberTransactionFilters: Value(null),
    ),
    updateSharedEntry: false,
  );
  return true;
}

Future<bool> leaveSharedBudget(Budget sharedBudget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (!_shareAvailable) {
    return false;
  }
  removeMemberFromBudget(sharedBudget.sharedKey!,
      shareBackend.currentUserEmail!, sharedBudget);
  removedSharedFromBudget(sharedBudget, removeFromServer: false);
  return true;
}

Future<bool> addMemberToBudget(
    String sharedKey, String member, Budget budget) async {
  if (!_shareAvailable) {
    return false;
  }
  await shareBackend.updateMembers(sharedKey, member, add: true);
  Budget budgetFromDB = await database.getBudgetInstance(budget.budgetPk);
  List<String> memberList = budgetFromDB.sharedMembers ?? [];
  memberList.add(member);
  Set<String> allMembersEver =
      (budgetFromDB.sharedAllMembersEver ?? []).toSet();
  allMembersEver.add(member);
  await database.createOrUpdateBudget(
    budgetFromDB.copyWith(
      sharedMembers: Value(memberList),
      sharedAllMembersEver: Value(
        allMembersEver.toList(),
      ),
    ),
    updateSharedEntry: false,
  );
  return true;
}

Future<bool> removeMemberFromBudget(
    String sharedKey, String member, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (!_shareAvailable) {
    return false;
  }
  await shareBackend.updateMembers(sharedKey, member, add: false);
  Budget budgetFromDB = await database.getBudgetInstance(budget.budgetPk);
  List<String> memberList = budgetFromDB.sharedMembers ?? [];
  memberList.remove(member);
  await database.createOrUpdateBudget(
    budgetFromDB.copyWith(
      sharedMembers: Value(memberList),
    ),
    updateSharedEntry: false,
  );
  return true;
}

// the owner is always the first entry!
Future<dynamic> getMembersFromBudget(String sharedKey, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (!_shareAvailable) {
    return null;
  }
  Map<String, dynamic>? budgetDecoded =
      await shareBackend.getSharedBudget(sharedKey);
  if (budgetDecoded == null) {
    return null;
  }
  List<String> memberList = [
    budgetDecoded["ownerEmail"].toString(),
    ...List<String>.from(budgetDecoded["members"])
  ];
  await database.createOrUpdateBudget(
    budget.copyWith(sharedMembers: Value(memberList)),
    updateSharedEntry: false,
  );
  return memberList;
}

Future<bool> compareSharedToCurrentBudgets(
    List<SharedBudgetSnapshot> budgetSnapshot) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  List<Budget> budgets = await database.getAllBudgets();
  for (Budget budget in budgets) {
    if (budget.sharedKey != null) {
      bool found = false;
      for (SharedBudgetSnapshot budgetCloud in budgetSnapshot) {
        if (budgetCloud.id == budget.sharedKey) {
          found = true;
          break;
        }
      }
      if (found == false) {
        openSnackbar(SnackbarMessage(
            icon: appStateSettings["outlinedIcons"]
                ? Icons.remove_circle_outline_outlined
                : Icons.remove_circle_outline_rounded,
            title: budget.name,
            description: "Is no longer shared with you"));
        removedSharedFromBudget(budget);
      }
    }
  }
  for (SharedBudgetSnapshot budgetCloud in budgetSnapshot) {
    bool found = false;
    for (Budget budget in budgets) {
      if (budget.sharedKey != null && budgetCloud.id == budget.sharedKey) {
        found = true;
        break;
      }
    }
    if (found == false) {
      Map<String, dynamic> budgetDecoded = budgetCloud.data;
      openSnackbar(SnackbarMessage(
        title: budgetDecoded["name"].toString() + " was shared with you",
        description: "From " + getMemberNickname(budgetDecoded["ownerEmail"]),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.share_outlined
            : Icons.share_rounded,
      ));
    }
  }
  return true;
}

Timer? cloudTimeoutTimer;
Future<bool> getCloudBudgets() async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (appStateSettings["hasSignedIn"] == false) return false;
  if (errorSigningInDuringCloud == true) return false;
  if (kIsWeb && !entireAppLoaded) return false;
  if (cloudTimeoutTimer?.isActive == true) {
    return false;
  } else {
    cloudTimeoutTimer = Timer(Duration(milliseconds: 5000), () {
      cloudTimeoutTimer!.cancel();
    });
  }
  if (!_shareAvailable) {
    return false;
  }

  List<SharedBudgetSnapshot> sharedBudgets =
      await shareBackend.listSharedBudgets();

  await compareSharedToCurrentBudgets(sharedBudgets);

  int totalTransactionsUpdated =
      await downloadTransactionsFromBudgets(sharedBudgets);
  int amountSynced = sharedBudgets.length;
  if (amountSynced > 0 && totalTransactionsUpdated > 0)
    openSnackbar(
      SnackbarMessage(
        icon: appStateSettings["outlinedIcons"]
            ? Icons.cloud_sync_outlined
            : Icons.cloud_sync_rounded,
        title: "synced".tr() +
            " " +
            totalTransactionsUpdated.toString() +
            " " +
            pluralString(totalTransactionsUpdated == 1, "change"),
        description: "From " +
            amountSynced.toString() +
            " shared " +
            pluralString(amountSynced == 1, "budget"),
      ),
    );
  return true;
}

Future<int> downloadTransactionsFromBudgets(
    List<SharedBudgetSnapshot> snapshots) async {
  if (appStateSettings["sharedBudgets"] == false) return 0;
  int totalUpdated = 0;
  for (SharedBudgetSnapshot budget in snapshots) {
    Set<String> allMembersEver = {};
    Map<String, dynamic> budgetDecoded = budget.data;
    await database.createOrUpdateFromSharedBudget(
      insert: true,
      Budget(
        budgetPk: "-1",
        name: budgetDecoded["name"],
        amount: budgetDecoded["amount"].toDouble(),
        colour: budgetDecoded["colour"],
        startDate: budgetDecoded["startDate"],
        endDate: budgetDecoded["endDate"],
        categoryFks: null,
        addedTransactionsOnly: true,
        periodLength: budgetDecoded["periodLength"],
        reoccurrence: mapRecurrence(budgetDecoded["reoccurrence"]),
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        pinned: true,
        order: 0,
        walletFk: "0",
        sharedKey: budget.id,
        sharedOwnerMember:
            shareBackend.currentUserEmail == budgetDecoded["ownerEmail"]
                ? SharedOwnerMember.owner
                : SharedOwnerMember.member,
        sharedMembers: [
          budgetDecoded["ownerEmail"],
          ...List<String>.from(budgetDecoded["members"]),
        ],
        budgetTransactionFilters: [],
        memberTransactionFilters: null,
        isAbsoluteSpendingLimit: false,
        income: false,
        archived: false,
      ),
    );

    // Get transactions from the server
    Budget sharedBudget = await database.getSharedBudget(budget.id);
    List<SharedTransactionLog> logs = await shareBackend.listTransactionLogs(
      budget.id,
      since: sharedBudget.sharedDateUpdated,
    );
    totalUpdated = totalUpdated + logs.length;
    for (SharedTransactionLog transaction in logs) {
      Map<String, dynamic> transactionDecoded = transaction.data;
      if (transactionDecoded["logType"] == "create" ||
          transactionDecoded["logType"] == "update") {
        TransactionCategory selectedCategory;
        try {
          selectedCategory = await database
              .getCategoryInstanceGivenName(transactionDecoded["categoryName"]);
        } catch (_) {
          int numberOfCategories =
              (await database.getTotalCountOfCategories())[0] ?? 0;
          await database.createOrUpdateCategory(
            insert: true,
            TransactionCategory(
              categoryPk: "-1",
              name: transactionDecoded["categoryName"],
              dateCreated: DateTime.now(),
              dateTimeModified: null,
              order: numberOfCategories,
              income: false,
              iconName: transactionDecoded["categoryIcon"],
              colour: transactionDecoded["categoryColour"],
              methodAdded: MethodAdded.shared,
            ),
          );
          selectedCategory = await database
              .getCategoryInstanceGivenName(transactionDecoded["categoryName"]);
        }

        await database.createOrUpdateFromSharedTransaction(
          insert: true,
          Transaction(
            transactionPk: "-1",
            name: transactionDecoded["name"],
            amount: transactionDecoded["amount"].toDouble(),
            note: transactionDecoded["note"],
            categoryFk: selectedCategory.categoryPk,
            walletFk: "0",
            dateCreated: transactionDecoded["dateTimeCreated"],
            dateTimeModified: null,
            income: transactionDecoded["income"],
            paid: true,
            skipPaid: false,
            sharedKey: transaction.id,
            sharedOldKey: transaction.id,
            transactionOwnerEmail: transactionDecoded["ownerEmail"],
            transactionOriginalOwnerEmail:
                transactionDecoded["originalCreatorEmail"],
            methodAdded: MethodAdded.shared,
            sharedDateUpdated: DateTime.now(),
            sharedStatus: SharedStatus.shared,
            sharedReferenceBudgetPk: sharedBudget.budgetPk,
          ),
        );
        if (transactionDecoded["ownerEmail"] != null)
          allMembersEver.add(transactionDecoded["ownerEmail"]);
        if (transactionDecoded["name"] != null &&
            transactionDecoded["name"] != "")
          await addAssociatedTitles(
              transactionDecoded["name"], selectedCategory);
      } else if (transactionDecoded["logType"] == "delete") {
        try {
          await database.deleteFromSharedTransaction(
              transactionDecoded["deleteSharedKey"]);
        } catch (e) {
          print("This shared transaction already deleted" + e.toString());
        }
      }
    }
    Budget budgetAlreadyStored = (await database.getSharedBudget(budget.id));
    allMembersEver.addAll((budgetAlreadyStored.sharedMembers ?? []).toSet());
    allMembersEver
        .addAll((budgetAlreadyStored.sharedAllMembersEver ?? []).toSet());
    await database.createOrUpdateFromSharedBudget(sharedBudget.copyWith(
        sharedDateUpdated: Value(DateTime.now()),
        sharedAllMembersEver: Value(allMembersEver.toList())));
  }

  return totalUpdated;
}

/// Records an action in the outgoing queue so it can be retried once a share
/// backend is available.
void _queueAction(
  Transaction transaction,
  Budget budget,
  String action, {
  bool useSharedKey = false,
}) {
  Map<dynamic, dynamic> currentSendTransactionsToServerQueue =
      appStateSettings["sendTransactionsToServerQueue"];
  currentSendTransactionsToServerQueue[transaction.transactionPk.toString()] = {
    "action": action,
    if (useSharedKey)
      "transactionSharedKey": transaction.sharedKey.toString()
    else
      "transactionPk": transaction.transactionPk.toString(),
    "budgetPk": budget.budgetPk.toString(),
  };
  updateSettings(
    "sendTransactionsToServerQueue",
    currentSendTransactionsToServerQueue,
    pagesNeedingRefresh: [],
    updateGlobalState: false,
  );
}

Future<bool> sendTransactionSet(Transaction transaction, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (!_shareAvailable) {
    _queueAction(transaction, budget, "sendTransactionSet");
    return false;
  }
  await setOnServer(transaction, budget);
  return true;
}

// update the entry on the server
Future<bool> setOnServer(Transaction transaction, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  TransactionCategory transactionCategory =
      await database.getCategoryInstance(transaction.categoryFk);
  await shareBackend.setTransactionLog(
    budget.sharedKey!,
    transaction.sharedKey,
    {
      "logType": "update", // create, delete, update
      "name": transaction.name,
      "amount": transaction.amount,
      "note": transaction.note,
      "dateTimeCreated": transaction.dateCreated,
      "dateUpdated": DateTime.now(),
      "income": transaction.income,
      "ownerEmail": transaction.transactionOwnerEmail, //ownerEmail is the payer
      "categoryName": transactionCategory.name,
      "categoryIcon": transactionCategory.iconName, //emoji icons not supported
      "categoryColour": transactionCategory.colour,
    },
  );
  transaction = transaction.copyWith(
    sharedStatus: Value(SharedStatus.shared),
    sharedDateUpdated: Value(DateTime.now()),
    sharedOldKey: Value(transaction.sharedKey),
  );
  await database.createOrUpdateTransaction(transaction,
      updateSharedEntry: false);
  return true;
}

Future<bool> sendTransactionAdd(Transaction transaction, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (!_shareAvailable) {
    _queueAction(transaction, budget, "sendTransactionAdd");
    return false;
  }
  await addOnServer(transaction, budget);
  return true;
}

Future<bool> addOnServer(Transaction transaction, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  TransactionCategory transactionCategory =
      await database.getCategoryInstance(transaction.categoryFk);
  String addedKey = await shareBackend.addTransactionLog(budget.sharedKey!, {
    "logType": "create", // create, delete, update
    "name": transaction.name,
    "amount": transaction.amount,
    "note": transaction.note,
    "dateTimeCreated": transaction.dateCreated,
    "dateUpdated": DateTime.now(),
    "income": transaction.income,
    "ownerEmail": transaction.transactionOwnerEmail, //ownerEmail is the payer
    "originalCreatorEmail": shareBackend.currentUserEmail,
    "categoryName": transactionCategory.name,
    "categoryIcon": transactionCategory.iconName, //emoji icons not supported
    "categoryColour": transactionCategory.colour,
  });
  transaction = transaction.copyWith(
    sharedKey: Value(addedKey),
    sharedOldKey: Value(addedKey),
    transactionOwnerEmail: Value(transaction.transactionOwnerEmail),
    transactionOriginalOwnerEmail: Value(shareBackend.currentUserEmail),
    sharedStatus: Value(SharedStatus.shared),
    sharedDateUpdated: Value(DateTime.now()),
  );
  await database.createOrUpdateTransaction(transaction,
      updateSharedEntry: false);
  return true;
}

Future<bool> sendTransactionDelete(
    Transaction transaction, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (!_shareAvailable) {
    _queueAction(transaction, budget, "sendTransactionDelete",
        useSharedKey: true);
    return false;
  }
  await deleteOnServer(transaction.sharedKey, budget);
  return true;
}

Future<bool> deleteOnServer(
    String? transactionSharedKey, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (transactionSharedKey != null && transactionSharedKey != "null") {
    await shareBackend.addTransactionLog(budget.sharedKey!, {
      "logType": "delete", // create, delete, update
      "deleteSharedKey": transactionSharedKey,
      "dateUpdated": DateTime.now(),
    });
    await shareBackend.deleteTransactionLog(
        budget.sharedKey!, transactionSharedKey);
  }
  return true;
}

Future<bool> syncPendingQueueOnServer() async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (appStateSettings["hasSignedIn"] == false) return false;
  if (errorSigningInDuringCloud == true) return false;
  if (kIsWeb && !entireAppLoaded) return false;
  Map<dynamic, dynamic> currentSendTransactionsToServerQueue =
      appStateSettings["sendTransactionsToServerQueue"];
  for (String key in currentSendTransactionsToServerQueue.keys) {
    if (!_shareAvailable) {
      return false;
    }
    try {
      Budget budget;
      try {
        budget = await database.getBudgetInstance(
            currentSendTransactionsToServerQueue[key]["budgetPk"].toString());
      } catch (e) {
        print(e.toString());
        // budget was probably deleted, we don't need to sync anything...
        continue;
      }

      if (currentSendTransactionsToServerQueue[key]["action"] ==
          "sendTransactionDelete") {
        await deleteOnServer(
            currentSendTransactionsToServerQueue[key]["transactionSharedKey"],
            budget);
      }

      Transaction transaction = await database.getTransactionFromPk(
          currentSendTransactionsToServerQueue[key]["transactionPk"]
              .toString());
      if (currentSendTransactionsToServerQueue[key]["action"] ==
          "sendTransactionSet") {
        await setOnServer(transaction, budget);
      } else if (currentSendTransactionsToServerQueue[key]["action"] ==
          "sendTransactionAdd") {
        await addOnServer(transaction, budget);
      }
    } catch (e) {
      print(e.toString());
      print("skipping syncing this transaction...");
    }
  }
  updateSettings("sendTransactionsToServerQueue", {},
      pagesNeedingRefresh: [], updateGlobalState: false);
  return true;
}

Future<bool> updateTransactionOnServerAfterChangingCategoryInformation(
    TransactionCategory category) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  loadingIndeterminateKey.currentState?.setVisibility(true);
  List<Transaction> sharedTransactionsInCategory =
      await database.getAllTransactionsSharedInCategory(category.categoryPk);

  List<Future> asyncCalls = [];
  for (Transaction transaction in sharedTransactionsInCategory) {
    // update all shared transactions one by one, need to update the server
    if (transaction.sharedReferenceBudgetPk != null) {
      Budget budget = await database
          .getBudgetInstance(transaction.sharedReferenceBudgetPk!);
      asyncCalls.add(sendTransactionSet(transaction, budget));
    }
  }
  await Future.wait(asyncCalls);
  loadingIndeterminateKey.currentState?.setVisibility(false);
  return true;
}
