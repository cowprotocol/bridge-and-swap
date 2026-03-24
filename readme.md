# Bridge and swap

> [!WARNING]
> This repository is experimental! It's developed in the context of a hackaton, it's not ready to use and may contain important security vulnerability. Use this code at your own risk!

Bridge funds to a different chain, then automatically have an order created on CoW that sells these funds.

## Structure

This repo is divided in three parts. The code for each part is described in its own folder.

- `contracts`
  The smart contracts handling the order after funds are bridged.
- `backend`
  The service indexing contracts & creating new orders on the CoW API.
- `frontend`
  An interface for the user to create orders.
