# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.BbNsk.Doctor do
  @shortdoc "Checks that the board is showing the hardware this package expects"
  @moduledoc """
  #{@shortdoc}

  Run it on the board, over SSH:

  ```elixir
  Mix.Tasks.BbNsk.Doctor.run([])
  ```

  It checks the handful of things that account for nearly every "it doesn't
  work" on one of these, and says what to do about each. Nearly all of them come
  back to one cause: **the board booted the wrong device tree**, and everything
  the add-on needs is missing at once.

  Read-only. It claims nothing and changes nothing, so it is safe to run against
  a robot that is balancing.
  """

  use Mix.Task

  alias Nerves.Runtime.KV

  @checks [
    {:device_tree, "device tree"},
    {:pwm, "motor PWM"},
    {:imu, "BMI323 IMU"},
    {:leds, "NeoPixels"},
    {:panel, "e-paper panel"}
  ]

  @doc false
  @impl Mix.Task
  def run(_argv) do
    results = Enum.map(@checks, fn {check, label} -> {label, check(check)} end)

    Enum.each(results, fn {label, {status, detail}} ->
      Mix.shell().info("#{marker(status)} #{label}: #{detail}")
    end)

    failures = Enum.filter(results, fn {_label, {status, _detail}} -> status == :error end)

    if failures == [] do
      Mix.shell().info("\nEverything the Balance Bot needs is here.")
    else
      Mix.shell().info("\n" <> advice(failures))
    end

    :ok
  end

  defp marker(:ok), do: "ok  "
  defp marker(:warn), do: "??  "
  defp marker(:error), do: "FAIL"

  # `fit_config` is an ordinary U-Boot variable and `Nerves.Runtime.KV` is backed
  # by the U-Boot environment, so this reads what the board will boot next time
  # rather than what it booted this time. They differ exactly once: after someone
  # has run the `put/2` below and not yet rebooted.
  defp check(:device_tree) do
    case kv_get("fit_config") do
      "nsk-balance-bot" -> {:ok, "nsk-balance-bot"}
      nil -> {:warn, "no fit_config set — not a Trellis board, or not running Nerves"}
      other -> {:error, "#{other}, which reaches none of the add-on board"}
    end
  end

  # Eight channels on the T113's controller, of which the add-on uses 2 to 5.
  defp check(:pwm) do
    case File.read("/sys/class/pwm/pwmchip0/npwm") do
      {:ok, count} -> {:ok, "pwmchip0, #{String.trim(count)} channels"}
      {:error, _reason} -> {:error, "no pwmchip0, so neither motor can be driven"}
    end
  end

  # 0x68 on `i2c-0`. The device tree muxes `i2c0` onto both pin pairs — the base
  # sensors' and the add-on's — so all four devices share one bus, which is why
  # the base sensors answering is not evidence that the add-on's does.
  defp check(:imu) do
    case detect("i2c-0") do
      {:error, reason} ->
        {:error, reason}

      addresses ->
        if 0x68 in addresses do
          {:ok, "0x68 on i2c-0"}
        else
          {:error, "nothing at 0x68 on i2c-0, found #{inspect(addresses, base: :hex)}"}
        end
    end
  end

  defp check(:leds) do
    case File.ls("/sys/class/leds") do
      {:ok, leds} ->
        case Enum.filter(leds, &String.starts_with?(&1, "rgb:indicator")) do
          [] -> {:error, "no rgb:indicator LEDs, so the ledc node is missing"}
          found -> {:ok, "#{length(found)} NeoPixels"}
        end

      {:error, _reason} ->
        {:error, "no /sys/class/leds at all"}
    end
  end

  defp check(:panel) do
    if File.exists?("/dev/spidev0.0") do
      {:ok, "spidev0.0"}
    else
      {:error, "no spidev0.0, so the panel can't be reached"}
    end
  end

  defp advice(failures) do
    labels = Enum.map_join(failures, ", ", fn {label, _result} -> label end)

    """
    Failing: #{labels}.

    If several of these failed at once, suspect the device tree rather than the
    hardware — the stock `nerves-starter-kit` tree has no motor PWM, no `i2c0`
    on the add-on's pins and no `ledc` node, so they all go missing together.

    Fix it live, taking effect on the next boot, with no reflash:

        Nerves.Runtime.KV.put("fit_config", "nsk-balance-bot")
        Nerves.Runtime.reboot()

    A board burned from firmware built with `bb_nsk.install`'s
    `config/provisioning.conf` comes up right on its own. Note that `mix upload`
    never rewrites the U-Boot environment, so an OTA can neither break this nor
    repair it.
    """
  end

  # Both are optional dependencies: a project that never reached
  # `bb_nsk.install` may not have them, and neither exists on a host that isn't
  # running Nerves. `Code.ensure_loaded?/1` is the guard; the calls themselves
  # are ordinary, because the module is known even when its presence isn't.
  defp kv_get(key) do
    if Code.ensure_loaded?(KV), do: KV.get(key)
  end

  defp detect(bus) do
    if Code.ensure_loaded?(Circuits.I2C) do
      Circuits.I2C.detect_devices(bus)
    else
      {:error, "circuits_i2c is not available, so the bus can't be scanned"}
    end
  rescue
    _ -> {:error, "#{bus} could not be opened"}
  end
end
